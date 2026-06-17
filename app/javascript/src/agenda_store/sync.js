// Sync layer for AgendaStore — handles the network side of bootstrap,
// delta, and lazy backfill (page). Subscribes to the Monitor agenda
// broadcast to drive incremental refresh; rolls over to a fresh
// bootstrap on logical-day change so the carry-over set and today
// markers stay correct.
//
// Shape:
//   AgendaSync.boot()                 — fire on every page load. Returns
//                                       Promise that resolves once first
//                                       authoritative payload lands.
//   AgendaSync.scheduleDelta()        — debounced poll for delta since
//                                       last server_ts. Called by the
//                                       Monitor handler on broadcast.
//   AgendaSync.ensureRangeLoaded(from, to)
//                                     — pulls a page if any portion of
//                                       the range is below the store's
//                                       known floor. Used by the cal
//                                       views when the user jumps to
//                                       historical dates.

const Store = require("./store");

const ENDPOINTS = {
  bootstrap: "/agenda/sync/bootstrap",
  delta:     "/agenda/sync/delta",
  page:      "/agenda/sync/page",
};

let bootPromise = null;
let lastSyncTs = readLastSyncTs();
let deltaTimer = null;
let pageInflight = new Map(); // key -> Promise (dedupe identical lazy pulls)

function readLastSyncTs() {
  if (typeof window === "undefined" || !window.localStorage) return 0;
  return Number(window.localStorage.getItem(Store.LS_LAST_SYNC_TS) || "0") || 0;
}

function writeLastSyncTs(ts) {
  lastSyncTs = ts;
  if (typeof window === "undefined" || !window.localStorage) return;
  try { window.localStorage.setItem(Store.LS_LAST_SYNC_TS, String(ts)); }
  catch (err) { /* ignore */ }
}

async function fetchJSON(url, opts) {
  const res = await fetch(url, Object.assign({
    credentials: "same-origin",
    headers: { Accept: "application/json" },
  }, opts || {}));
  if (!res.ok) throw new Error(`${url} → ${res.status}`);
  return await res.json();
}

// Cold-start. Hydrates from localStorage so the user sees the last-
// known calendar in the first paint, then fires the network bootstrap
// in the background to refresh. Subsequent calls return the same
// Promise to dedupe simultaneous boots from multiple subscribers.
function boot() {
  if (bootPromise) return bootPromise;

  const hadCache = Store.hydrateFromLocal();
  const rolledOver = hadCache && Store.isDayRolledOver();

  bootPromise = (async () => {
    try {
      const payload = await fetchJSON(ENDPOINTS.bootstrap);
      Store.applyBootstrap(payload);
      writeLastSyncTs(payload.server_ts);
    } catch (err) {
      console.warn("[AgendaSync] bootstrap failed", err);
      // We still have whatever was in localStorage; subscriber paints
      // from that. Caller can retry by re-invoking boot() after a wait.
    }
  })();

  return bootPromise.then(() => ({ hadCache, rolledOver }));
}

function scheduleDelta() {
  if (deltaTimer) return;
  // Coalesce broadcast bursts (Google sync can fire many in a row when
  // catching up). 200ms is short enough to feel instantaneous, long
  // enough to batch a flurry.
  deltaTimer = setTimeout(() => {
    deltaTimer = null;
    runDelta().catch((err) => console.warn("[AgendaSync] delta failed", err));
  }, 200);
}

async function runDelta() {
  if (!lastSyncTs) {
    // Never bootstrapped — promote to full boot.
    return boot();
  }
  const sinceIso = new Date(lastSyncTs).toISOString();
  const payload = await fetchJSON(`${ENDPOINTS.delta}?since=${encodeURIComponent(sinceIso)}`);
  Store.applyDelta(payload);
  writeLastSyncTs(payload.server_ts);
}

// Lazy backfill. The store's `windowFrom` is the earliest date for
// which the bootstrap-or-page set is authoritative; if the caller
// wants a range earlier than that floor, fire a page request to cover
// it. Multiple concurrent calls collapse to one inflight request per
// (from, to) pair.
async function ensureRangeLoaded(fromISO, toISO) {
  const floor = Store.getWindowFrom();
  if (!floor || fromISO >= floor) return; // nothing to backfill
  const effectiveTo = toISO < floor ? toISO : addDays(floor, -1);
  const key = `${fromISO}..${effectiveTo}`;
  if (pageInflight.has(key)) return pageInflight.get(key);
  const p = (async () => {
    try {
      const url = `${ENDPOINTS.page}?from=${encodeURIComponent(fromISO)}&to=${encodeURIComponent(effectiveTo)}`;
      const payload = await fetchJSON(url);
      Store.applyPage(payload);
    } catch (err) {
      console.warn("[AgendaSync] page failed", err);
    } finally {
      pageInflight.delete(key);
    }
  })();
  pageInflight.set(key, p);
  return p;
}

function addDays(iso, n) {
  const [y, m, d] = String(iso).split("-").map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d + n, 12, 0, 0));
  const yy = dt.getUTCFullYear();
  const mm = String(dt.getUTCMonth() + 1).padStart(2, "0");
  const dd = String(dt.getUTCDate()).padStart(2, "0");
  return `${yy}-${mm}-${dd}`;
}

// Monitor subscription. Hooks the shared agenda broadcast channel —
// any change to an item / schedule / preference / agenda triggers
// either a preference-only patch (no fetch) or a debounced delta
// (catches the change + any other concurrent changes). Falls back
// gracefully if the Monitor singleton isn't loaded yet (page-init
// order is preimports → src/**); the boot() handler will register
// once it's available.
function subscribeMonitor() {
  if (typeof window === "undefined" || !window.Monitor) return false;
  if (subscribeMonitor.subscribed) return true;
  subscribeMonitor.subscribed = true;

  window.Monitor.subscribe("agenda", {
    received(data) {
      if (!data || data.id !== "agenda") return;
      // Inline preference snapshot — applied locally without a fetch.
      if (data.data && data.data.preferences) {
        Store.setPreferences(data.data.preferences);
        return;
      }
      scheduleDelta();
    },
    connected() {
      // Reconnect after a drop: catch up anything we missed while the
      // socket was down.
      scheduleDelta();
    },
  });
  return true;
}

// Belt-and-suspenders: PWAs / mobile occasionally lose the websocket
// without firing disconnect; refresh on focus/online so we recover.
function installResumeTriggers() {
  if (typeof window === "undefined") return;
  if (installResumeTriggers.installed) return;
  installResumeTriggers.installed = true;
  window.addEventListener("focus", () => scheduleDelta());
  window.addEventListener("online", () => scheduleDelta());
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") scheduleDelta();
  });
}

const AgendaSync = {
  boot,
  scheduleDelta,
  runDelta,
  ensureRangeLoaded,
  subscribeMonitor,
  installResumeTriggers,
  endpoints: ENDPOINTS,
};

if (typeof module !== "undefined" && module.exports) module.exports = AgendaSync;
if (typeof window !== "undefined") window.AgendaSync = AgendaSync;
