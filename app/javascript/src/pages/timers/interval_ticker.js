// Unconditional setInterval-based ticker. Every 250ms, iterates every
// running countdown in the store and re-applies its renderer's update().
// Reliable across reloads (no kick-on-change brittleness), pauses
// implicitly when the tab is hidden via the visibilitychange listener
// in index.js (which also triggers a server sync to reconcile drift).

export class IntervalTicker {
  constructor({ store, board, intervalMs = 250 }) {
    this.store = store;
    this.board = board;
    this.handle = setInterval(() => this.tick(), intervalMs);
  }

  tick() {
    const running = this.store.runningCountdowns();
    if (running.length === 0) return;
    for (const t of running) {
      const r = this.board.renderers.get(t.id);
      if (r?.update) {
        try { r.update(t); } catch (e) { console.error("Timer tick failed:", e); }
      }
    }
  }

  destroy() {
    if (this.handle) clearInterval(this.handle);
    this.handle = null;
  }
}
