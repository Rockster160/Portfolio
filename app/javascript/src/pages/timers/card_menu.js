// Per-card action menu. Reordering is the dedicated edit-mode + drag
// flow on the Board — NOT a menu item. Counter cards get a "Set value"
// entry that prompts for a target and dispatches the delta as an
// increment (which respects min/max).

export function setupCardMenu({ root, store, actions, openEdit }) {
  const menu = document.createElement("div");
  menu.className = "timers-card-menu-popup hidden";
  menu.setAttribute("role", "menu");
  root.appendChild(menu);

  let currentTimerId = null;

  function close() {
    menu.classList.add("hidden");
    currentTimerId = null;
  }

  function rebuild(timer) {
    const isCounter = timer.kind === "counter";
    const disableLabel = timer.disabled ? "Enable" : "Disable";
    menu.innerHTML = `
      <button type="button" data-action="edit">Edit</button>
      <button type="button" data-action="duplicate">Duplicate</button>
      ${isCounter ? '<button type="button" data-action="set-value">Set value…</button>' : ""}
      ${isCounter ? '<button type="button" data-action="reset">Reset to start</button>' : ""}
      ${timer.kind === "countdown" ? '<button type="button" data-action="reset">Reset timer</button>' : ""}
      ${timer.kind === "dial"      ? '<button type="button" data-action="reset">Reset to start</button>' : ""}
      <button type="button" data-action="toggle-disabled">${disableLabel}</button>
      <button type="button" data-action="delete" class="danger">Delete</button>
    `;
  }

  function open(timerId, anchorBtn) {
    currentTimerId = timerId;
    const t = store.timers.get(timerId);
    if (!t) return;
    rebuild(t);
    menu.classList.remove("hidden");
    requestAnimationFrame(() => {
      const rect = anchorBtn.getBoundingClientRect();
      const rootRect = root.getBoundingClientRect();
      const w = menu.offsetWidth || 170;
      menu.style.top  = `${rect.bottom - rootRect.top + 4}px`;
      menu.style.left = `${Math.max(8, rect.right - rootRect.left - w)}px`;
    });
  }

  menu.addEventListener("click", async (e) => {
    const btn = e.target.closest("button[data-action]");
    if (!btn) return;
    const action = btn.dataset.action;
    const timer = store.timers.get(currentTimerId);
    if (!timer) { close(); return; }
    close();

    if (action === "edit") {
      openEdit({ timer });
      return;
    }
    if (action === "duplicate") {
      const dup = { ...timer };
      delete dup.id;
      delete dup.started_at;
      delete dup.end_at;
      delete dup.fired_at;
      delete dup.confirmed_at;
      delete dup.paused_at;
      delete dup.paused_remaining_ms;
      await actions.create({ ...dup, name: timer.name ? `${timer.name} copy` : "" });
      return;
    }
    if (action === "set-value") {
      const target = window.prompt("Set value to:", String(timer.value ?? 0));
      if (target === null) return;
      const n = parseInt(target, 10);
      if (Number.isNaN(n)) { alert("Not a number."); return; }
      const delta = n - (timer.value || 0);
      if (delta !== 0) await actions.increment(timer.id, delta);
      return;
    }
    if (action === "reset") {
      await actions.reset(timer.id);
      return;
    }
    if (action === "toggle-disabled") {
      await actions.update(timer.id, { disabled: !timer.disabled });
      return;
    }
    if (action === "delete") {
      if (!confirm("Delete this timer?")) return;
      await actions.destroy(timer.id);
    }
  });

  document.addEventListener("click", (e) => {
    if (menu.classList.contains("hidden")) return;
    if (menu.contains(e.target)) return;
    if (e.target.closest("[data-timer-menu]")) return;
    close();
  });
  document.addEventListener("keydown", (e) => { if (e.key === "Escape") close(); });

  return { open, close };
}
