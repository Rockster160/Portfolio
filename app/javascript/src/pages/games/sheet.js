// One bottom sheet at a time, shared by every Games page. A sheet is a
// backdrop plus a panel appended to the page's .games-app; tapping the
// backdrop, the × or Escape closes it. Callers render the body HTML and
// wire it in `onMount(panel)`; `refresh(html)` swaps the body in place so a
// sheet can redraw (a running total) without the open animation replaying.
import { esc } from "./util";

let current = null;

export function closeSheet() {
  if (!current) return;
  const { backdrop, panel, onClose } = current;
  current = null;
  backdrop.remove();
  panel.remove();
  document.removeEventListener("keydown", onKey);
  if (onClose) onClose();
}

function onKey(e) {
  if (e.key === "Escape") closeSheet();
}

export function openSheet({ title, body, onMount, onClose }) {
  closeSheet();
  const host = document.querySelector(".games-app") || document.body;

  const backdrop = document.createElement("div");
  backdrop.className = "games-sheet-backdrop";
  backdrop.addEventListener("click", closeSheet);

  const panel = document.createElement("div");
  panel.className = "games-sheet";
  panel.setAttribute("role", "dialog");
  panel.setAttribute("aria-modal", "true");

  host.append(backdrop, panel);
  current = { backdrop, panel, onClose, onMount, title };
  document.addEventListener("keydown", onKey);
  draw(body);
  return { refresh: draw, panel };

  function draw(html) {
    if (!current || current.panel !== panel) return;
    panel.innerHTML = `
      <div class="games-sheet-grip"></div>
      <div class="games-sheet-head">
        <h2>${esc(title)}</h2>
        <button type="button" class="games-icon-btn" data-sheet-close aria-label="Close">✕</button>
      </div>
      ${html}
    `;
    panel.querySelector("[data-sheet-close]").addEventListener("click", closeSheet);
    if (onMount) onMount(panel);
  }
}

export function sheetIsOpen() {
  return current !== null;
}
