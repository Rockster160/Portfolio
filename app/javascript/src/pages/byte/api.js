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

// Cap individual fetches so a hung request can't hold the `draining`
// lock and block every subsequent send. This is the root cause of the
// "pending for 20-30 seconds" the user was seeing: without a timeout,
// fetch waits on the browser's default socket idle (often ~30s on iOS),
// and every new send while a prior one is stuck sees `draining = true`
// and no-ops until that timeout resolves.
const SEND_TIMEOUT_MS = 8000;
const CSRF_TIMEOUT_MS = 4000;

function fetchWithTimeout(url, options = {}, timeoutMs = SEND_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  return fetch(url, { ...options, signal: controller.signal })
    .finally(() => clearTimeout(timer));
}

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
    const res = await fetchWithTimeout(CSRF_REFRESH_URL, {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    }, CSRF_TIMEOUT_MS);
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

  const doFetch = (token) => fetchWithTimeout(SEND_URL, {
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

// Which entries are currently in flight (either a fresh send or a
// drainQueue attempt). `drainQueue` skips anything in this set so a
// direct send + concurrent drain sweep can't double-POST the same entry.
const inFlight = new Set();

async function processEntry(entry, hooks) {
  if (inFlight.has(entry.local_id)) return;
  inFlight.add(entry.local_id);
  try {
    hooks.onSending?.(entry);
    const result = await trySend(entry);

    if (result.status === "ok") {
      removeByLocalId(entry.local_id);
      hooks.onSent?.(entry, result.message);
    } else if (result.status === "transient") {
      // Entry stays in the queue and gets retried on the next drain
      // trigger. Never dropped — the user hit send, they want it
      // delivered whenever the network allows.
      markAttempt(entry.local_id);
      hooks.onTransientFail?.(entry, result.reason);
    } else {
      // Permanent 4xx (not auth): the server explicitly refused this
      // exact payload. Retrying won't fix it.
      removeByLocalId(entry.local_id);
      hooks.onPermanentFail?.(entry, result.reason, result.code);
    }
  } finally {
    inFlight.delete(entry.local_id);
  }
}

// Enqueue for durability + fire IMMEDIATELY. The direct call skips the
// drainQueue lock so the user's send never waits behind an older stuck
// entry — that was the source of the 20-30s "pending" the user was
// seeing. drainQueue still runs in parallel to sweep any older queued
// items; the `inFlight` guard prevents double-POST.
export function sendMessage(entry, hooks = {}) {
  enqueue(entry);
  hooks.onEnqueued?.(entry);
  processEntry(entry, hooks);
  drainQueue(hooks);
}

// One drain sweep in flight at a time. If a new send arrives mid-sweep,
// the current sweep re-loops after finishing so nothing else stagnates
// waiting for an external trigger.
let draining = false;
let redrainNeeded = false;

export async function drainQueue(hooks = {}) {
  if (draining) {
    redrainNeeded = true;
    return;
  }
  if (!navigator.onLine) return;

  draining = true;
  try {
    do {
      redrainNeeded = false;
      const entries = all();
      for (const entry of entries) {
        // Skip anything the direct-send path is already handling.
        if (inFlight.has(entry.local_id)) continue;
        await processEntry(entry, hooks);
      }
    } while (redrainNeeded);
  } finally {
    draining = false;
  }
}
