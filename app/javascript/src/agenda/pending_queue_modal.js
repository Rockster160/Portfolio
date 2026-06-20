// Inspector + manual-control surface for the offline mutation queue.
// The `.agenda-pending-badge` in every agenda view header opens this
// modal on click; the modal lists every queued op with a delete button
// per row so the user can drop changes they don't actually want to send.
//
// Subscribes to AgendaMutationQueue so the list rebuilds whenever the
// queue changes (drain, enqueue, cross-tab storage event).
//
// Per the never-block-user rule: this modal is OPT-IN — the badge is a
// subtle icon-only count, the user opens this only when they want to
// see what's pending.

(function () {
  if (typeof window === "undefined") return;

  document.addEventListener("DOMContentLoaded", () => {
    const modal = document.getElementById("agenda-pending-queue");
    if (!modal) return;
    if (!window.AgendaMutationQueue) return;

    // Open on badge click — there's one .agenda-pending-badge per page;
    // it's in the header partial included by every agenda shell.
    document.querySelectorAll(".agenda-pending-badge").forEach((badge) => {
      badge.style.cursor = "pointer";
      badge.setAttribute("role", "button");
      badge.setAttribute("aria-haspopup", "dialog");
      badge.setAttribute("aria-controls", "agenda-pending-queue");
      badge.setAttribute("tabindex", "0");
      const open = (e) => {
        e.preventDefault();
        e.stopPropagation();
        renderList(modal);
        if (typeof window.showModal === "function") window.showModal("#agenda-pending-queue");
      };
      badge.addEventListener("click", open);
      badge.addEventListener("keydown", (e) => {
        if (e.key === "Enter" || e.key === " ") open(e);
      });
    });

    // Live-update list while the modal is open (e.g. another tab drains).
    window.AgendaMutationQueue.subscribe(() => {
      if (modal.classList.contains("hidden")) return;
      renderList(modal);
    });

    // "Retry now" — manual nudge to the drain. Useful when the user
    // just came back online and doesn't want to wait for the next event.
    modal.querySelector("[data-pending-retry]")?.addEventListener("click", () => {
      window.AgendaMutationQueue.flush();
    });

    modal.querySelector("[data-pending-list]")?.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-drop-mid]");
      if (!btn) return;
      dropMutation(btn.dataset.dropMid);
      renderList(modal);
    });
  });

  function renderList(modal) {
    const list = modal.querySelector("[data-pending-list]");
    const empty = modal.querySelector("[data-pending-empty]");
    const retry = modal.querySelector("[data-pending-retry]");
    if (!list) return;

    const ops = window.AgendaMutationQueue.loadQueue();
    list.innerHTML = "";

    if (ops.length === 0) {
      if (empty) empty.hidden = false;
      if (retry) retry.hidden = true;
      return;
    }
    if (empty) empty.hidden = true;
    if (retry) retry.hidden = false;

    ops.forEach((op) => {
      const li = document.createElement("li");
      li.className = "agenda-pending-modal-item";

      const meta = document.createElement("div");
      meta.className = "agenda-pending-modal-meta";
      const label = document.createElement("span");
      label.className = "agenda-pending-modal-kind";
      label.textContent = describe(op);
      meta.appendChild(label);
      const sub = document.createElement("span");
      sub.className = "agenda-pending-modal-when";
      sub.textContent = relativeTime(op.queued_at);
      meta.appendChild(sub);
      li.appendChild(meta);

      const drop = document.createElement("button");
      drop.type = "button";
      drop.className = "agenda-pending-modal-drop af-btn af-btn-secondary";
      drop.setAttribute("data-drop-mid", op.client_mutation_id);
      drop.setAttribute("aria-label", "Drop this pending change");
      drop.textContent = "Drop";
      li.appendChild(drop);

      list.appendChild(li);
    });
  }

  // Surface a friendly label for the op so the user knows what they're
  // looking at without having to read the raw URL/method.
  function describe(op) {
    const k = (op.kind || "").toLowerCase();
    if (k === "create") return `Add — ${itemName(op) || "new item"}`;
    if (k === "create-schedule") return `Add recurring — ${itemName(op) || "new series"}`;
    if (k === "update") return `Edit — ${itemName(op) || op.target_id || "item"}`;
    if (k === "destroy") return `Delete — ${op.target_id || "item"}`;
    if (k === "complete") return `Check — ${op.target_id || "item"}`;
    if (k === "uncomplete") return `Uncheck — ${op.target_id || "item"}`;
    if (k === "restore") return `Restore to series`;
    return `${(op.method || "OP").toUpperCase()} ${op.url || ""}`;
  }

  function itemName(op) {
    return op?.body?.agenda_item?.name || op?.body?.agenda_schedule?.name || "";
  }

  function relativeTime(iso) {
    if (!iso) return "";
    const then = new Date(iso).getTime();
    if (!then) return "";
    const diffMs = Date.now() - then;
    const secs = Math.round(diffMs / 1000);
    if (secs < 60) return `${secs}s ago`;
    const mins = Math.round(secs / 60);
    if (mins < 60) return `${mins}m ago`;
    const hrs = Math.round(mins / 60);
    if (hrs < 24) return `${hrs}h ago`;
    return `${Math.round(hrs / 24)}d ago`;
  }

  // Manually drop an op the user no longer wants to send. We also
  // reverse the optimistic store mutation when reasonable — for
  // creates we remove the temp:* row that the user can see; for
  // updates/destroys/completes the local change stays in place
  // because the user already saw + accepted that change. Reverting
  // those silently would surprise them more than the in-place stale
  // local copy. The next bootstrap will reconcile.
  function dropMutation(mid) {
    if (!mid) return;
    const queue = window.AgendaMutationQueue.loadQueue();
    const op = queue.find((p) => p.client_mutation_id === mid);
    if (!op) return;
    const remaining = queue.filter((p) => p.client_mutation_id !== mid);
    try { localStorage.setItem("agenda:mutation_queue:v1", JSON.stringify(remaining)); }
    catch (err) { console.error("[agenda queue] drop persist failed", err); }
    window.dispatchEvent(new StorageEvent("storage", { key: "agenda:mutation_queue:v1" }));

    if (op.kind === "create" && op.target_id && String(op.target_id).startsWith("temp:")) {
      if (window.AgendaStore) window.AgendaStore.removeItem(op.target_id);
    }
  }
})();
