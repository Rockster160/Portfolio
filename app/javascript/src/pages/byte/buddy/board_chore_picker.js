// Picking a chore on a board - what a pin is, what a credit button completes.
// The same search the Chores page uses (name, short name and aliases; see
// chore_search.js) over a grid of the chores' own icons, so one can be found
// by what it's called AND recognized by how it looks. A modal <dialog>, so it
// sits over every control on the screen.

import { searchChores } from "../../../chore_search";

export function initBoardChorePicker({ dialog, iconFor }) {
  if (!dialog) return { open: async () => null };

  const titleEl = dialog.querySelector("[data-bcp-title]");
  const searchEl = dialog.querySelector("[data-bcp-search]");
  const gridEl = dialog.querySelector("[data-bcp-grid]");
  const emptyEl = dialog.querySelector("[data-bcp-empty]");
  const cancelEl = dialog.querySelector("[data-bcp-cancel]");

  let chores = [];
  let settle = null;

  function finish(chore) {
    const done = settle;
    settle = null;
    if (dialog.open) dialog.close();
    done?.(chore);
  }

  function render() {
    const matches = searchChores(chores, searchEl?.value || "");
    const cells = matches.map((chore) => {
      const cell = document.createElement("button");
      cell.type = "button";
      cell.className = "byte-board-chore-cell";
      const icon = document.createElement("span");
      icon.className = "byte-board-chore-cell-icon";
      icon.appendChild(iconFor(chore));
      const label = document.createElement("span");
      label.className = "byte-board-chore-cell-label";
      label.textContent = chore.short_name || chore.name;
      cell.title = chore.name;
      cell.append(icon, label);
      cell.addEventListener("click", () => finish(chore));
      return cell;
    });
    gridEl?.replaceChildren(...cells);
    if (emptyEl) emptyEl.hidden = cells.length > 0;
  }

  searchEl?.addEventListener("input", render);
  cancelEl?.addEventListener("click", () => finish(null));
  // Escape, or the dialog closed any other way, is a pick of nothing.
  dialog.addEventListener("close", () => finish(null));
  dialog.addEventListener("click", (e) => {
    if (e.target === dialog) finish(null);
  });

  return {
    // Resolves to the chosen chore, or null. `options` are the chores to offer
    // (the board's chore list); `exclude` drops ids already taken.
    open({ options = [], exclude = [], title = "Pick a chore" } = {}) {
      const skip = new Set(exclude.map(Number));
      chores = options.filter((c) => !skip.has(Number(c.id)));
      if (titleEl) titleEl.textContent = title;
      if (searchEl) searchEl.value = "";
      render();
      return new Promise((resolve) => {
        settle = resolve;
        dialog.showModal();
        searchEl?.focus();
      });
    },
  };
}
