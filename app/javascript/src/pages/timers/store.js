// In-memory store. Every record carries an `updated_at` from the SERVER
// (Rails-stamped on save; included by TimerSerializer / serialize_page /
// serialize_quick). All upserts compare those server timestamps with
// `isNewerOrEqual()` so stale broadcasts arriving out of order cannot
// overwrite a fresher local copy.
//
// IMPORTANT: this module never generates its own timestamps. `lastSyncTs`
// is whatever the server returned on the last sync — not modified.

function asMs(stamp) {
  if (!stamp) return null;
  const ms = Date.parse(stamp);
  return Number.isNaN(ms) ? null : ms;
}

// True if the incoming row is at least as recent as the existing one.
// If either side has no usable timestamp we accept the incoming row
// (first-write paths and entities without updated_at).
function isNewerOrEqual(existing, incoming) {
  const e = asMs(existing?.updated_at);
  const i = asMs(incoming?.updated_at);
  if (e == null || i == null) return true;
  return i >= e;
}

export class TimerStore {
  constructor() {
    this.timers = new Map();
    this.pages = new Map();
    this.quickButtons = new Map();
    this.subscribers = new Set();
    this.lastSyncTs = null;
    this.activeShareTokens = [];
  }

  subscribe(fn) {
    this.subscribers.add(fn);
    return () => this.subscribers.delete(fn);
  }

  notify(kind, payload) {
    this.subscribers.forEach((fn) => {
      try { fn(kind, payload); } catch (e) { console.error(e); }
    });
  }

  loadBootstrap(bootstrap) {
    (bootstrap.timers || []).forEach((t) => this.timers.set(t.id, t));
    (bootstrap.pages || []).forEach((p) => this.pages.set(p.id, p));
    (bootstrap.quick_buttons || []).forEach((q) => this.quickButtons.set(q.id, q));
    this.activeShareTokens = bootstrap.active_share_tokens || [];
    this.lastSyncTs = bootstrap.server_ts || null;
    this.notify("bootstrap", { bootstrap });
  }

  // `source` is propagated to subscribers so they can choose how
  // aggressively to refresh: "broadcast" callers force a full re-mount,
  // "action" callers (this tab's own mutation responses) can update in
  // place.
  //
  // `force: true` skips the isNewerOrEqual check and unconditionally
  // applies the incoming row. Used for live broadcasts (the server is
  // authoritative at that moment — if a chain target's inline state
  // arrives, we want it in the store immediately even if our local
  // clock skew makes the existing updated_at look "newer").
  upsertTimer(t, { silent = false, source = null, force = false } = {}) {
    if (!t || t.id == null) return;
    const existing = this.timers.get(t.id);
    if (!force && existing && !isNewerOrEqual(existing, t)) return;
    this.timers.set(t.id, t);
    if (!silent) this.notify("timer", { id: t.id, timer: t, source });
  }

  removeTimer(id) {
    if (!this.timers.has(id)) return;
    this.timers.delete(id);
    this.notify("timer_removed", { id });
  }

  upsertPage(p) {
    if (!p || p.id == null) return;
    const existing = this.pages.get(p.id);
    if (existing && !isNewerOrEqual(existing, p)) return;
    this.pages.set(p.id, p);
    this.notify("page", { id: p.id });
  }

  removePage(id) {
    this.pages.delete(id);
    this.notify("page_removed", { id });
  }

  upsertQuick(q) {
    if (!q || q.id == null) return;
    const existing = this.quickButtons.get(q.id);
    if (existing && !isNewerOrEqual(existing, q)) return;
    this.quickButtons.set(q.id, q);
    this.notify("quick", { id: q.id });
  }

  removeQuick(id) {
    this.quickButtons.delete(id);
    this.notify("quick_removed", { id });
  }

  applySync(diff) {
    (diff.timers || []).forEach((t) => this.upsertTimer(t, { silent: true, source: "sync" }));
    (diff.pages || []).forEach((p) => {
      const existing = this.pages.get(p.id);
      if (existing && !isNewerOrEqual(existing, p)) return;
      this.pages.set(p.id, p);
    });
    (diff.quick_buttons || []).forEach((q) => {
      const existing = this.quickButtons.get(q.id);
      if (existing && !isNewerOrEqual(existing, q)) return;
      this.quickButtons.set(q.id, q);
    });
    (diff.archived_ids || []).forEach((id) => this.timers.delete(id));
    // Server timestamp passed through verbatim. NEVER modified here —
    // sync queries since this exact server moment.
    if (diff.server_ts) this.lastSyncTs = diff.server_ts;
    this.notify("sync", { diff });
  }

  runningCountdowns() {
    const out = [];
    for (const t of this.timers.values()) {
      if (t.kind === "countdown" && t.started_at && !t.paused_at && !t.fired_at) {
        out.push(t);
      }
    }
    return out;
  }
}
