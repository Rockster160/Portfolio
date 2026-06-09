// Thin action layer over `api`. Every mutation here updates the local
// store with the server response so the UI reflects the change without
// waiting for a Monitor broadcast (which is filtered out for the actor
// tab by design). Use this from renderers / card menu / modals instead
// of calling `api` directly for stateful timer changes.

export function makeActions({ api, store }) {
  function applyTimer(res) {
    // Source = "action" tells the board this update came from THIS tab's
    // own mutation response (vs a cross-tab broadcast). The board can
    // update in place — no need to force a full re-mount for our own
    // taps.
    //
    // `force: true` because the response carries the server's
    // post-save state of the timer; no FE timestamp arithmetic should
    // ever override that. (Same reasoning as applySync / inline
    // broadcast.)
    if (res?.timer) store.upsertTimer(res.timer, { source: "action", force: true });
    return res;
  }

  return {
    start:     async (id) => applyTimer(await api.start(id)),
    pause:     async (id) => applyTimer(await api.pause(id)),
    resume:    async (id) => applyTimer(await api.resume(id)),
    reset:     async (id) => applyTimer(await api.reset(id)),
    confirm:   async (id) => applyTimer(await api.confirm(id)),
    increment: async (id, by) => applyTimer(await api.increment(id, by)),
    advance:   async (id, by) => applyTimer(await api.advance(id, by)),

    create:    async (attrs) => applyTimer(await api.create(attrs)),
    update:    async (id, attrs) => applyTimer(await api.update(id, attrs)),
    destroy:   async (id) => {
      await api.destroy(id);
      store.removeTimer(id);
    },
    reorder:   (ids) => api.reorder(ids),
    layout:    async (id, geom) => applyTimer(await api.layout(id, geom)),

    createQuick:  async (attrs) => {
      const res = await api.createQuick(attrs);
      if (res) store.upsertQuick(res);
      return res;
    },
    updateQuick:  async (id, attrs) => {
      const res = await api.updateQuick(id, attrs);
      if (res) store.upsertQuick(res);
      return res;
    },
    destroyQuick: async (id) => {
      await api.destroyQuick(id);
      store.removeQuick(id);
    },
    reorderQuick: (ids) => api.reorderQuick(ids),

    createPage:  async (attrs) => {
      const res = await api.createPage(attrs);
      if (res) store.upsertPage(res);
      return res;
    },
    updatePage:  async (id, attrs) => {
      const res = await api.updatePage(id, attrs);
      if (res) store.upsertPage(res);
      return res;
    },
    destroyPage: async (id) => {
      await api.destroyPage(id);
      store.removePage(id);
    },

    createShare:  (attrs) => api.createShare(attrs),
    updateShare:  (id, attrs) => api.updateShare(id, attrs),
    destroyShare: (id) => api.destroyShare(id),
  };
}
