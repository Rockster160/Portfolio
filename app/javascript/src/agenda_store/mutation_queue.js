// Offline-first mutation queue for the agenda PWA. Mirrors the Chores
// pattern: every mutation writes to BOTH the AgendaStore (optimistic
// state) AND the persisted queue BEFORE attempting any network. The
// user can dismiss the app the instant they click — the queue replays
// next time the app opens, in the background if a tab is alive, on a
// fresh boot otherwise.
//
// Contract per queue item:
//   {
//     client_mutation_id: <uuid>,     // identity across retries / dedup
//     queued_at:          <iso8601>,  // user's wall-clock at click time
//     kind:               <"create"|"update"|"destroy"|"complete"|"rsvp">,
//     url:                <string>,   // mutation endpoint
//     method:             <"POST"|"PATCH"|"DELETE">,
//     body:               <object>,   // request payload (client_mutation_id embedded)
//     temp_id?:           <"temp:..."> // optimistic id, swapped on confirm
//   }
//
// Flush strategy:
//   * single-flight; concurrent flush() calls collapse into one drain
//   * head-of-line: drain in FIFO so order is preserved
//   * 4xx → permanent failure; drop the op into the "dropped" bucket
//     so the existing dismissable banner surfaces it. The optimistic
//     store mutation stays — the user manually undoes if needed.
//   * 5xx / network → exponential backoff, halt and retry on next
//     online/visibility/connect trigger
//   * 200 with `deduped: true` → idempotent retry confirmed; treat as
//     a normal success
//
// The Service Worker is set to network-only for mutations and returns
// a synthetic 503 when offline, so the queue's offline fallback kicks
// in seamlessly without page-side network detection logic.

const QUEUE_KEY    = "agenda:mutation_queue:v1";
const DROPPED_KEY  = "agenda:mutation_dropped:v1";
const TAB_ID_KEY   = "agenda:tab_id:v1";

function newMutationId() {
  if (typeof window !== "undefined" && window.crypto && window.crypto.randomUUID) {
    return window.crypto.randomUUID();
  }
  return `m-${Date.now()}-${Math.random().toString(36).slice(2, 12)}`;
}

function newTempId() {
  return `temp:${newMutationId()}`;
}

function tabId() {
  try {
    let id = sessionStorage.getItem(TAB_ID_KEY);
    if (!id) {
      id = newMutationId();
      sessionStorage.setItem(TAB_ID_KEY, id);
    }
    return id;
  } catch (_) {
    return "no-storage";
  }
}

function loadQueue() {
  try { return JSON.parse(localStorage.getItem(QUEUE_KEY) || "[]"); }
  catch (_) { return []; }
}

function saveQueue(q) {
  try {
    localStorage.setItem(QUEUE_KEY, JSON.stringify(q));
  } catch (err) {
    console.error("[agenda queue] persist failed (quota / storage disabled)", err);
  }
  notifySubscribers();
}

function loadDropped() {
  try { return JSON.parse(localStorage.getItem(DROPPED_KEY) || "[]"); }
  catch (_) { return []; }
}

function saveDropped(list) {
  try { localStorage.setItem(DROPPED_KEY, JSON.stringify(list)); }
  catch (err) { console.error("[agenda queue] dropped persist failed", err); }
  notifySubscribers();
}

// ----- subscription -----

const subscribers = new Set();
function subscribe(fn) {
  subscribers.add(fn);
  return () => subscribers.delete(fn);
}
function notifySubscribers() {
  subscribers.forEach((fn) => {
    try { fn(loadQueue(), loadDropped()); }
    catch (err) { console.warn("[agenda queue] subscriber error", err); }
  });
}

// Cross-tab coordination — when another tab drains an op, refresh our
// view of the queue (badge, dropped banner). The dedup_key + server's
// client_mutation_id idempotency prevent double-send.
if (typeof window !== "undefined") {
  window.addEventListener("storage", (e) => {
    if (e.key === QUEUE_KEY || e.key === DROPPED_KEY) notifySubscribers();
  });
  // Belt-and-braces re-notify on focus/visibility/online — if a
  // subscriber missed an update (e.g. the badge was painted before the
  // mutation queue module finished loading, or a cross-tab storage
  // event got dropped by the browser under load), the spinner can
  // otherwise stay visible after the underlying queue is empty.
  // Cheap idempotent call — subscribers all read the live queue length.
  ["focus", "online"].forEach((evt) => {
    window.addEventListener(evt, () => notifySubscribers());
  });
  if (typeof document !== "undefined") {
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") notifySubscribers();
    });
  }
}

// ----- enqueue -----

// Adds an op to the queue. If an op with the same `client_mutation_id`
// or a same-target `dedup_key` already sits there (e.g. user typed,
// paused, typed again), the latest body wins but the original
// client_mutation_id + queued_at are preserved so the server's
// idempotency lookup still matches the first attempt.
function enqueue(op) {
  if (!op || !op.url || !op.method) return;
  const q = loadQueue();
  const stamped = Object.assign({
    queued_at:          new Date().toISOString(),
    client_mutation_id: op.client_mutation_id || newMutationId(),
  }, op);

  const idx = q.findIndex((p) =>
    p.client_mutation_id === stamped.client_mutation_id ||
    (op.dedup_key && p.dedup_key === op.dedup_key)
  );
  if (idx >= 0) {
    // Preserve the original identity but update body + payload to the
    // freshest version so a debounced typed edit collapses cleanly.
    stamped.client_mutation_id = q[idx].client_mutation_id;
    stamped.queued_at          = q[idx].queued_at;
    q[idx] = stamped;
  } else {
    q.push(stamped);
  }
  saveQueue(q);
  return stamped;
}

// ----- flush -----

let flushing = false;
let backoffMs = 0;
// 500ms first retry (was 2s) — the pending-spinner badge is keyed off
// queue length, so a single transient 5xx used to keep the badge
// visible for 2 full seconds after the underlying mutation actually
// recovered on retry. 500ms still gives a real server breathing room
// without that visual lag.
const BACKOFF_BASE = 500;
const BACKOFF_CAP  = 60_000;

async function flush() {
  if (flushing) return;
  flushing = true;
  try {
    while (true) {
      const q = loadQueue();
      if (q.length === 0) { backoffMs = 0; return; }

      const op = q[0];
      let res;
      try {
        res = await fetch(op.url, {
          method:      op.method,
          credentials: "same-origin",
          headers: {
            "Content-Type":         "application/json",
            "Accept":               "application/json",
            "X-CSRF-Token":         csrfToken(),
            "X-Requested-With":     "XMLHttpRequest",
            "X-Client-Mutation-At": String(Date.parse(op.queued_at) || Date.now()),
            "X-Agenda-Tab-Id":      tabId(),
          },
          body: op.body ? JSON.stringify(op.body) : undefined,
        });
      } catch (_e) {
        // Network drop — leave queued, schedule a retry. The page-side
        // resume triggers (online / visibility / Monitor reconnect) will
        // call flush() again.
        scheduleRetry();
        return;
      }

      if (res.ok || res.status === 409) {
        // 200 / 201 / 204: server accepted. 409: server has a fresher
        // version and gave us the canonical row — either way the op is
        // resolved; drop the head of the queue. The response (if JSON)
        // feeds the store reconciliation hook.
        const payload = await readJson(res);
        popHead(op);
        // Clear pending UI markers BEFORE the reconciler runs — same
        // contract as `queue_reconciler.js#clearPendingMarkers` but lives
        // here as a backstop so the lifecycle never depends on a single
        // hook firing. A failure inside `onMutationResolved` (subscriber
        // throws, store guard short-circuits, etc.) used to strand the
        // row in `.is-pending` forever; doing it here guarantees the
        // class clears on every successful resolve.
        clearPendingMarkersForOp(op, payload);
        if (payload && typeof onMutationResolved === "function") {
          try { onMutationResolved(op, payload, { conflict: res.status === 409 }); }
          catch (err) { console.warn("[agenda queue] reconcile hook error", err); }
        }
        backoffMs = 0;
        continue;
      }

      if (res.status >= 400 && res.status < 500) {
        // Permanent failure — drop into the user-visible dismissable
        // bucket so they see what didn't apply. The optimistic store
        // change stays put; the user manually reverts if needed.
        popHead(op);
        const dropped = loadDropped();
        dropped.push({
          client_mutation_id: op.client_mutation_id,
          url:                op.url,
          method:             op.method,
          status:             res.status,
          dropped_at:         new Date().toISOString(),
        });
        saveDropped(dropped);
        continue;
      }

      // 5xx — transient. Halt + retry.
      scheduleRetry();
      return;
    }
  } finally {
    flushing = false;
  }
}

function popHead(op) {
  const q = loadQueue();
  if (q[0] && q[0].client_mutation_id === op.client_mutation_id) {
    q.shift();
    saveQueue(q);
  }
}

// Strip the optimistic `.is-pending` / `.is-pending-delete` markers stamped
// in `agenda.js` at submit time. Matched DOM nodes are anything carrying
// the op's `target_id` OR the canonical id returned in the response, so a
// `temp:` row swapped out by `upsertItem`'s reconciliation still gets
// cleaned up properly.
function clearPendingMarkersForOp(op, payload) {
  if (typeof document === "undefined") return;
  const itemPayload = payload && payload.current && typeof payload.current === "object"
    ? payload.current
    : payload;
  const ids = new Set();
  if (op && op.target_id) ids.add(String(op.target_id));
  if (itemPayload && itemPayload.id) ids.add(String(itemPayload.id));
  ids.forEach((id) => {
    if (!id) return;
    const esc = (window.CSS && window.CSS.escape)
      ? window.CSS.escape(id)
      : String(id).replace(/"/g, '\\"');
    document.querySelectorAll(`[data-item-id="${esc}"]`).forEach((el) => {
      el.classList.remove("is-pending");
      el.classList.remove("is-pending-delete");
    });
  });
}

function scheduleRetry() {
  backoffMs = Math.min(backoffMs ? backoffMs * 2 : BACKOFF_BASE, BACKOFF_CAP);
  setTimeout(() => { flush().catch(() => {}); }, backoffMs);
}

async function readJson(res) {
  try { return await res.json(); }
  catch (_) { return null; }
}

function csrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta ? meta.getAttribute("content") : "";
}

// Reconciliation hook — set by the bootstrap script so the queue can
// dispatch into the store without a circular import. Receives:
//   onMutationResolved(op, responsePayload, { conflict })
let onMutationResolved = null;
function setReconcileHook(fn) { onMutationResolved = fn; }

// ----- dropped bucket -----

function dismissDropped() {
  saveDropped([]);
}

// ----- public surface -----

const AgendaMutationQueue = {
  enqueue,
  flush,
  loadQueue,
  loadDropped,
  dismissDropped,
  subscribe,
  setReconcileHook,
  newMutationId,
  newTempId,
  tabId,
  QUEUE_KEY,
  DROPPED_KEY,
};

if (typeof module !== "undefined" && module.exports) module.exports = AgendaMutationQueue;
if (typeof window !== "undefined") {
  window.AgendaMutationQueue = AgendaMutationQueue;
  // Auto-drain on connectivity returning so a pending queue replays
  // immediately when the user comes back online — they don't have to
  // wait for a render tick or interaction.
  window.addEventListener("online", () => flush().catch(() => {}));
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") flush().catch(() => {});
  });
  // On page load, drain whatever sat in the queue from a previous
  // session (offline edit + browser quit, app killed mid-flight).
  window.addEventListener("load", () => flush().catch(() => {}));
}
