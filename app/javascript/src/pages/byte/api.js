// HTTP layer for the Byte page.
//
// Design: NO drain lock, NO ordering constraint. Every entry is fired
// the moment it's added; each entry's own attempt tracks itself via
// the `inFlight` Set to prevent duplicate POSTs. Simpler and lower
// latency than the previous queue-lock architecture — the queue is
// still there purely for OFFLINE durability (so nothing is lost across
// reloads), not for coordinating in-flight work.

import { enqueue, all, removeByLocalId, markAttempt } from "./queue";

let SEND_URL = null;
let CSRF_REFRESH_URL = "/byte/csrf";

export function configure({ sendUrl, csrfRefreshUrl }) {
  if (sendUrl) SEND_URL = sendUrl;
  if (csrfRefreshUrl) CSRF_REFRESH_URL = csrfRefreshUrl;
}

// Bounded so a hung request can never wedge things. Every fetch aborts
// at this deadline and surfaces as a transient failure — the entry
// stays queued for the next drain trigger.
const SEND_TIMEOUT_MS = 8000;
const CSRF_TIMEOUT_MS = 4000;

function fetchWithTimeout(url, options = {}, timeoutMs = SEND_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  return fetch(url, { ...options, signal: controller.signal })
    .finally(() => clearTimeout(timer));
}

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

async function trySend(entry) {
  const payload = {
    local_id: entry.local_id,
    body:     entry.body,
    // Client-side timestamp travels with the payload so the server can
    // use it as the message's created_at. That way rapid sends stay in
    // client-typed order even when the network delivers them to the
    // server out of order.
    client_ts: entry.client_ts,
    source:   entry.metadata?.source || "web",
    metadata: entry.metadata || {},
  };

  const doFetch = (token) => fetchWithTimeout(SEND_URL, {
    method: "POST",
    credentials: "same-origin",
    // `keepalive` tells iOS Safari the request must complete even
    // during touch/scroll activity or navigation. Without it, Safari
    // will de-prioritise background fetches during active gestures —
    // that's what caused the "20 messages sitting until you stopped
    // sending" behaviour.
    keepalive: true,
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

    if (res.ok) return { status: "ok", message: await safeJson(res) };
    if (res.status >= 500) return { status: "transient", reason: `http_${res.status}` };
    if (res.status === 401 || res.status === 403) return { status: "transient", reason: "auth" };
    return { status: "permanent", reason: `http_${res.status}`, code: res.status };
  } catch (e) {
    return { status: "transient", reason: "network" };
  }
}

// Per-entry in-flight guard. Same entry can't have two concurrent POSTs
// even if both `sendMessage` (direct-fire) and `drainQueue` (sweep) call
// `attempt` on it at roughly the same time.
const inFlight = new Set();

async function attempt(entry, hooks) {
  if (inFlight.has(entry.local_id)) return;
  inFlight.add(entry.local_id);
  try {
    hooks.onSending?.(entry);
    const result = await trySend(entry);

    if (result.status === "ok") {
      removeByLocalId(entry.local_id);
      hooks.onSent?.(entry, result.message);
    } else if (result.status === "transient") {
      markAttempt(entry.local_id);
      hooks.onTransientFail?.(entry, result.reason);
      // Entry stays in queue; retried on next drainQueue trigger.
    } else {
      removeByLocalId(entry.local_id);
      hooks.onPermanentFail?.(entry, result.reason, result.code);
    }
  } finally {
    inFlight.delete(entry.local_id);
  }
}

// Enqueue for offline durability + fire immediately. No lock, no wait.
// The queue is there so a lost connection / closed tab preserves the
// message, not to serialise sends.
export function sendMessage(entry, hooks = {}) {
  enqueue(entry);
  hooks.onEnqueued?.(entry);
  attempt(entry, hooks);
}

// Sweep the queue — fires an `attempt` for each entry that isn't
// already in flight. All attempts run in parallel. Called on `online`,
// visibilitychange, MonitorChannel `connected`, and setInterval.
export function drainQueue(hooks = {}) {
  if (!navigator.onLine) return;
  const entries = all();
  for (const entry of entries) attempt(entry, hooks);
}
