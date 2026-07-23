// HTTP layer for the Byte page. Wraps outbound POSTs, handles CSRF
// refresh on 401/422, and drives the outbound queue drain.
//
// Ordering: each queued entry retries INDEPENDENTLY — a transient
// failure on one entry does not block later entries. Chat UX prefers
// "message N gets through" over "strict N-then-M-then-O ordering" when
// N is misbehaving.

import { enqueue, all, removeByLocalId, markAttempt } from "./queue";

let SEND_URL = null;
let CSRF_REFRESH_URL = "/byte/csrf";

// Called once from index.js so we can resolve URLs from data-attributes
// on the .byte-app element instead of hard-coding paths.
export function configure({ sendUrl, csrfRefreshUrl }) {
  if (sendUrl) SEND_URL = sendUrl;
  if (csrfRefreshUrl) CSRF_REFRESH_URL = csrfRefreshUrl;
}

// No transient-failure cap. Queue-tracked entries retry indefinitely on
// network / 5xx / auth-error until they succeed or the server explicitly
// refuses with a permanent 4xx. This is the right shape for chat: a
// message the user hit send on in an airport should still deliver when
// they land, even if that's days later. The `attempts` counter is still
// incremented (via markAttempt) for eventual exponential-backoff work
// or debugging visibility, but nothing acts on it.

function csrfMetaToken() {
  return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
}

async function refreshCsrf() {
  try {
    const res = await fetch(CSRF_REFRESH_URL, {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    });
    if (!res.ok) return null;
    const j = await res.json();
    if (j?.token) {
      const meta = document.querySelector('meta[name="csrf-token"]');
      if (meta) meta.setAttribute("content", j.token);
      return j.token;
    }
  } catch (e) {}
  return null;
}

async function safeJson(res) {
  try { return await res.json(); }
  catch (e) { return null; }
}

// Try a single POST for one entry. Return:
//   { status: :ok, message }             — server accepted, response body
//   { status: :transient, reason }       — retry later (network / 5xx / auth)
//   { status: :permanent, reason, code}  — drop from queue (4xx that isn't auth)
async function trySend(entry) {
  const payload = {
    local_id: entry.local_id,
    body:     entry.body,
    source:   entry.metadata?.source || "web",
    metadata: entry.metadata || {},
  };

  const doFetch = (token) => fetch(SEND_URL, {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      Accept:         "application/json",
      "X-CSRF-Token": token,
    },
    body: JSON.stringify(payload),
  });

  try {
    let token = csrfMetaToken();
    let res = await doFetch(token);

    if (res.status === 401 || res.status === 422) {
      const fresh = await refreshCsrf();
      if (fresh) res = await doFetch(fresh);
    }

    if (res.ok) {
      const message = await safeJson(res);
      return { status: "ok", message };
    }

    if (res.status >= 500) {
      return { status: "transient", reason: `http_${res.status}` };
    }

    if (res.status === 401 || res.status === 403) {
      return { status: "transient", reason: "auth" };
    }

    return { status: "permanent", reason: `http_${res.status}`, code: res.status };
  } catch (e) {
    return { status: "transient", reason: "network" };
  }
}

// Enqueue and kick off a drain. Synchronous — returns immediately.
// The visual `onEnqueued` fires right away; the network round-trip runs
// in the background.
export function sendMessage(entry, hooks = {}) {
  enqueue(entry);
  hooks.onEnqueued?.(entry);
  // Fire the drain without awaiting. Any errors are swallowed inside
  // drainQueue; callers care about individual message hooks, not a
  // batch-level rejection.
  drainQueue(hooks);
}

// One drain in flight at a time. If a new send arrives mid-drain, the
// current drain re-loops after finishing its pass so the new entry is
// picked up without waiting for the next external trigger.
let draining = false;
let redrainNeeded = false;

export async function drainQueue(hooks = {}) {
  if (draining) {
    // A drain is already processing; ask it to loop once more so any
    // just-enqueued entry gets a fair shot without waiting 30s.
    redrainNeeded = true;
    return;
  }
  if (!navigator.onLine) return;

  draining = true;
  try {
    do {
      redrainNeeded = false;
      const entries = all(); // snapshot at pass start
      for (const entry of entries) {
        hooks.onSending?.(entry);
        const result = await trySend(entry);

        if (result.status === "ok") {
          removeByLocalId(entry.local_id);
          hooks.onSent?.(entry, result.message);
        } else if (result.status === "transient") {
          // Entry stays in the queue and gets retried on the next drain
          // trigger (online / focus / setInterval / a new send). We never
          // drop it just because it's failed a few times — the user hit
          // send, they want it delivered whenever the network allows.
          markAttempt(entry.local_id);
          hooks.onTransientFail?.(entry, result.reason);
        } else {
          // Permanent 4xx (not auth): the server explicitly refused this
          // exact payload. Retrying won't fix it — drop and surface as
          // failed so the user sees why it didn't go through.
          removeByLocalId(entry.local_id);
          hooks.onPermanentFail?.(entry, result.reason, result.code);
        }
      }
    } while (redrainNeeded);
  } finally {
    draining = false;
  }
}
