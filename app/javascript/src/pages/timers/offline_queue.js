// localStorage-backed mutation queue. Pattern lifted from Chores: every
// state-changing fetch is wrapped — on network failure or 5xx the request
// is appended and replayed on next online event / focus / sync tick.

const QUEUE_KEY = "timers:offline_queue:v1";
const STORE_KEY = "timers:store:v1";
const SYNC_TS_KEY = "timers:last_sync_ts";

// Tab id is intentionally stored in module memory, NOT sessionStorage.
// Chrome (and other browsers) copy sessionStorage into duplicated tabs,
// so a `sessionStorage`-backed id ended up being the same in both the
// actor and the observer tabs — which made the observer treat the
// actor's broadcasts as its OWN echo and silently drop them. Each page
// load now generates a fresh UUID; duplicated tabs get distinct ids.
let CACHED_TAB_ID = null;
export function getTabId() {
  if (CACHED_TAB_ID) return CACHED_TAB_ID;
  CACHED_TAB_ID = (typeof crypto !== "undefined" && crypto.randomUUID)
    ? crypto.randomUUID()
    : `t-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  return CACHED_TAB_ID;
}

function readQueue() {
  try {
    return JSON.parse(localStorage.getItem(QUEUE_KEY) || "[]");
  } catch (e) {
    return [];
  }
}

function writeQueue(q) {
  localStorage.setItem(QUEUE_KEY, JSON.stringify(q));
}

export function enqueue(entry) {
  const q = readQueue();
  q.push({ ...entry, queued_at: Date.now() });
  writeQueue(q);
}

export function queueLength() {
  return readQueue().length;
}

export async function flushQueue({ csrfToken }) {
  const q = readQueue();
  if (q.length === 0) return { flushed: 0 };

  const remaining = [];
  let flushed = 0;

  for (const entry of q) {
    try {
      const res = await fetch(entry.url, {
        method: entry.method,
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "Accept":       "application/json",
          "X-CSRF-Token": csrfToken,
        },
        body: entry.body ? JSON.stringify(entry.body) : null,
      });
      if (res.ok) {
        flushed += 1;
      } else if (res.status === 401 || res.status === 403) {
        // Auth lost; bail and keep the rest queued for next session.
        remaining.push(entry);
        break;
      } else if (res.status >= 500) {
        remaining.push(entry);
      } else {
        // Permanent failure — drop the entry.
        flushed += 1;
      }
    } catch (e) {
      remaining.push(entry);
    }
  }

  writeQueue(remaining);
  return { flushed, remaining: remaining.length };
}

export function saveStoreSnapshot(store) {
  try {
    const snapshot = {
      timers:        Array.from(store.timers.values()),
      pages:         Array.from(store.pages.values()),
      quick_buttons: Array.from(store.quickButtons.values()),
      last_sync_ts:  store.lastSyncTs,
    };
    localStorage.setItem(STORE_KEY, JSON.stringify(snapshot));
    if (store.lastSyncTs) localStorage.setItem(SYNC_TS_KEY, store.lastSyncTs);
  } catch (e) { /* quota — ignore */ }
}

export function loadStoreSnapshot() {
  try {
    return JSON.parse(localStorage.getItem(STORE_KEY) || "null");
  } catch (e) {
    return null;
  }
}

export function lastSyncTs() {
  return localStorage.getItem(SYNC_TS_KEY) || null;
}
