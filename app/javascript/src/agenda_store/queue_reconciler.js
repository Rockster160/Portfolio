// Wires the mutation queue's drain results back into the AgendaStore.
// Mirrors the Chores pattern: when a queued op resolves (success or
// 409), the canonical row in the response gets upserted, which lets
// upsertItem's `client_mutation_id` reconciliation swap any optimistic
// `temp:` row for the server's real id. Subscribers re-render via the
// store notify, and the in-place patcher in `agenda_item_renderer.js`
// keeps the DOM identity intact across the swap.

(function () {
  if (typeof window === "undefined") return;
  if (!window.AgendaStore || !window.AgendaMutationQueue) return;

  window.AgendaMutationQueue.setReconcileHook((op, payload, ctx) => {
    if (!payload) return;

    // Most mutation endpoints return the canonical AgendaItem JSON
    // (sometimes nested under `current` for 409 Conflict). Detect both.
    const itemPayload = payload.current && typeof payload.current === "object"
      ? payload.current
      : payload;

    // Heuristic: the agenda-item shape carries `presentation_attrs` and
    // an `id`. Anything else (preference broadcasts, RSVP-only ack)
    // skips the upsert and lets the next delta sync handle it.
    if (itemPayload && itemPayload.id && itemPayload.presentation_attrs) {
      window.AgendaStore.upsertItem(itemPayload);
    }

    // For destroys, the server returns 204/empty — pop the optimistic
    // row out of the store too. The op carries the temp/real id we
    // sent so we know what to remove.
    if (op.method === "DELETE" && op.target_id) {
      window.AgendaStore.removeItem(op.target_id);
    }

    if (ctx && ctx.conflict) {
      // 409 already had its canonical row upserted above; nothing extra
      // to do here. The dropped-banner path is triggered by 4xx in the
      // queue's flush loop — 409 bypasses that because we accepted the
      // server's view.
    }
  });
})();
