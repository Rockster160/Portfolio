// Board: renders timer cards and owns the SortableJS instance used in
// edit mode. SortableJS is created on `enterEditMode()` and destroyed
// on `exitEditMode()`. Timers continue ticking during edit mode.
//
// On every timer update, the board re-checks BOTH whether the renderer
// can update in place AND whether the timer still belongs to the active
// page; moves between pages cause an unmount/mount instead of a stale
// "update in place" that would leave the card on the wrong page.

import { renderTimerCard } from "./renderers";
import Sortable from "../../../jil/Sortable.min.js";

export class Board {
  constructor({ root, store, actions, getActivePageId, onCardMenu, app }) {
    this.root = root;
    this.app = app;
    this.store = store;
    this.actions = actions;
    this.getActivePageId = getActivePageId;
    this.onCardMenu = onCardMenu;
    this.renderers = new Map();
    this.sortable = null;
    this.editMode = false;
    this.unsub = store.subscribe((kind, payload) => this.onChange(kind, payload));
  }

  destroy() {
    this.unsub?.();
    this.renderers.forEach((r) => r.dispose?.());
    this.renderers.clear();
    this.sortable?.destroy();
    this.sortable = null;
    this.root.innerHTML = "";
  }

  renderAll() {
    this.renderers.forEach((r) => r.dispose?.());
    this.renderers.clear();
    if (this.sortable) { this.sortable.destroy(); this.sortable = null; }
    this.root.innerHTML = "";

    const timers = this.visibleTimers();
    if (timers.length === 0) {
      const empty = document.createElement("p");
      empty.className = "timers-empty";
      empty.textContent = "No timers yet. Tap a quick-add above or the + button to create one.";
      this.root.appendChild(empty);
      return;
    }

    timers.forEach((t) => this.mount(t));
    if (this.editMode) this.installSortable();
  }

  visibleTimers() {
    const pageId = this.getActivePageId();
    // Mirror the server scope (pos_y DESC, id DESC) so newest lands at
    // the top without bumping anyone else's pos_y. id DESC is the
    // tiebreaker when multiple rows share pos_y (e.g. legacy 0s).
    return Array.from(this.store.timers.values())
      .filter((t) => (pageId == null ? t.timer_page_id == null : t.timer_page_id === pageId))
      .sort((a, b) => ((b.pos_y || 0) - (a.pos_y || 0)) || ((b.id || 0) - (a.id || 0)));
  }

  mount(timer) {
    const r = renderTimerCard(timer, this.actions);
    this.renderers.set(timer.id, r);
    // Mark home-page cards so CSS can selectively show the X-to-delete
    // button when the timer finishes. Custom pages don't get the X.
    if (this.getActivePageId() == null) r.node.classList.add("on-home");
    r.node.addEventListener("click", (e) => {
      const menuBtn = e.target.closest("[data-timer-menu]");
      if (!menuBtn) return;
      e.stopPropagation();
      this.onCardMenu?.(timer.id, menuBtn);
    });
    // Insert at the correct sort position. Find the next-sorted timer
    // whose node is already in the DOM and `insertBefore` it; otherwise
    // append. This keeps post-edit re-mounts in their original slot
    // instead of jumping to the end of the board.
    const sorted = this.visibleTimers();
    const myIdx = sorted.findIndex((t) => t.id === timer.id);
    let anchor = null;
    if (myIdx >= 0) {
      for (let i = myIdx + 1; i < sorted.length; i += 1) {
        const next = this.renderers.get(sorted[i].id);
        if (next?.node?.isConnected) { anchor = next.node; break; }
      }
    }
    if (anchor) this.root.insertBefore(r.node, anchor);
    else this.root.appendChild(r.node);
  }

  unmount(id) {
    const r = this.renderers.get(id);
    if (!r) return;
    r.dispose?.();
    r.node.remove();
    this.renderers.delete(id);
  }

  enterEditMode() {
    this.editMode = true;
    this.app?.classList.add("edit-mode");
    if (!this.sortable) this.installSortable();
  }

  exitEditMode() {
    this.editMode = false;
    this.app?.classList.remove("edit-mode");
    if (this.sortable) { this.sortable.destroy(); this.sortable = null; }
  }

  installSortable() {
    this.sortable = Sortable.create(this.root, {
      animation: 150,
      draggable: ".timer-card",
      ghostClass: "timer-card-ghost",
      chosenClass: "timer-card-chosen",
      dragClass: "timer-card-dragging",
      forceFallback: true,
      fallbackOnBody: true,
      fallbackTolerance: 0,
      filter: "[data-timer-menu], .timer-counter-btn, button, input, select",
      preventOnFilter: false,
      onEnd: () => {
        const ids = Array.from(this.root.querySelectorAll(".timer-card"))
          .map((el) => parseInt(el.dataset.timerId, 10))
          .filter(Boolean);
        if (ids.length === 0) return;
        // Top of the post-drag DOM order = highest pos_y, to match the
        // DESC scope. Optimistic store update; controller does the same
        // math server-side.
        ids.forEach((id, i) => {
          const t = this.store.timers.get(id);
          if (t) this.store.upsertTimer({ ...t, pos_y: ids.length - i }, { silent: true });
        });
        this.actions.reorder(ids);
      },
    });
  }

  onChange(kind, payload) {
    if (kind === "bootstrap" || kind === "sync" || kind === "page" || kind === "page_removed") {
      this.renderAll();
      return;
    }
    if (kind === "timer") {
      const t = payload.timer;
      const pageId = this.getActivePageId();
      const belongs = (pageId == null ? t.timer_page_id == null : t.timer_page_id === pageId);

      // Broadcasts ALWAYS trigger a full board re-render of visible
      // timers from current store state. Nothing in-place, nothing
      // fancy — guaranteed to reflect the new state because every
      // card is rebuilt from scratch off the store. Actions (own tab)
      // keep the optimized in-place path for smooth ring animation.
      if (payload.source === "broadcast") {
        this.renderAll();
        return;
      }

      const existing = this.renderers.get(payload.id);
      if (existing && !belongs) { this.unmount(payload.id); return; }
      if (!existing && belongs) { this.renderAll(); return; }
      if (!existing) return;

      const handled = existing.update(t);
      if (handled === false) {
        this.unmount(payload.id);
        this.mount(t);
      }
      return;
    }
    if (kind === "timer_removed") {
      this.unmount(payload.id);
    }
  }
}
