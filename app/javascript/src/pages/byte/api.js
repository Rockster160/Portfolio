// HTTP layer for the Byte page. Wraps outbound POSTs, handles CSRF
// refresh on 401/422, and drives the strict-FIFO drain of the offline
// queue. On network / 5xx failures the entry stays in the queue for the
// next drain trigger.

import { enqueue, head, removeByLocalId, markAttempt } from "./queue";

let SEND_URL = null;
let CSRF_REFRESH_URL = "/byte/csrf";

// Called once from index.js so we can resolve URLs from data-attributes
// on the .byte-app element instead of hard-coding paths.
export function configure({ sendUrl, csrfRefreshUrl }) {
  if (sendUrl) SEND_URL = sendUrl;
  if (csrfRefreshUrl) CSRF_REFRESH_URL = csrfRefreshUrl;
}

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

// Attempts a single POST for one entry. Returns:
//   { status: :ok, message }            — server accepted, response body
//   { status: :transient, reason }      — retry later (network / 5xx / auth)
//   { status: :permanent, reason, code} — drop from queue (4xx that isn't auth)
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

// Enqueue a message and immediately try to flush the queue. Callers
// pass `hooks` so the UI can reflect state transitions per entry.
export async function sendMessage(entry, hooks = {}) {
  enqueue(entry);
  hooks.onEnqueued?.(entry);
  await drainQueue(hooks);
}

// Strict FIFO drain. Stops at the first transient failure so ordering
// stays intact; drops entries that return permanent failures. Safe to
// call from multiple triggers — it just processes whatever's left.
let draining = false;
export async function drainQueue(hooks = {}) {
  if (draining) return;
  if (!navigator.onLine && !hooks.forceAttempt) return;

  draining = true;
  try {
    let sent = 0;
    while (true) {
      const entry = head();
      if (!entry) return { sent };

      hooks.onSending?.(entry);
      const result = await trySend(entry);

      if (result.status === "ok") {
        removeByLocalId(entry.local_id);
        hooks.onSent?.(entry, result.message);
        sent += 1;
        continue;
      }

      if (result.status === "transient") {
        markAttempt(entry.local_id);
        hooks.onTransientFail?.(entry, result.reason);
        return { sent, remaining: true };
      }

      // permanent
      removeByLocalId(entry.local_id);
      hooks.onPermanentFail?.(entry, result.reason, result.code);
      sent += 1;
    }
  } finally {
    draining = false;
  }
}
