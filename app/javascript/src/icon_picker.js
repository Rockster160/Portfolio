// Shared icon picker — search across emoji, Tabler icons and the household's
// own uploads, pick one, get its reference back.
//
// The POOL has always been shared (`icon_pool.js`, mirrored in Ruby); what
// wasn't was the surface for choosing from it. The chores modal builds its own
// out of `_icon_picker.html.erb` + ~150 lines inside `_page_script.html.erb`,
// bound to `[data-icon-stack]` and `chore-icon-picked` events, which makes it
// unusable anywhere else. This mounts its own DOM and takes a callback, so any
// page can open it. Byte's reactions are the first caller; the chores picker
// can move onto this later without either of them changing what a pick MEANS.
//
// A pick is one of three shapes, the same three IconPool produces:
//   * an emoji character     — "👍"
//   * a Tabler icon class    — "ti-flame"
//   * a household icon ref   — "hicon:12"

import { IconPool } from "./icon_pool";

const MAX_TILES = 240;

let modal = null;
let onPick = null;

// Render an icon reference into a container, whichever of the three shapes it
// is. Shared so a reference always LOOKS the same wherever it's shown.
export function renderIconValue(container, value) {
  container.replaceChildren();
  const v = String(value == null ? "" : value);
  if (!v) return;

  if (v.startsWith("hicon:")) {
    // Resolved against the already-loaded custom pool. A deleted icon collapses
    // to empty rather than a broken image.
    const src = IconPool.customSrcById(v.slice("hicon:".length));
    if (!src) return;
    const img = document.createElement("img");
    img.className = "icon-img";
    img.src = src;
    img.alt = "";
    img.draggable = false;
    container.appendChild(img);
    return;
  }
  if (v.startsWith("ti-")) {
    const i = document.createElement("i");
    i.className = `ti ${v}`;
    i.setAttribute("aria-hidden", "true");
    container.appendChild(i);
    return;
  }
  container.textContent = v;
}

// A reference whose picture needs the custom pool loaded before it can be
// drawn. Callers warm the pool when one of these is on screen.
export function needsIconPool(value) {
  return String(value == null ? "" : value).startsWith("hicon:");
}

export function warmIconPool() {
  return IconPool.load();
}

function buildModal() {
  const el = document.createElement("div");
  el.className = "icon-pick-pop";
  el.hidden = true;
  el.innerHTML = `
    <div class="icon-pick-sheet" role="dialog" aria-label="Pick an icon">
      <div class="icon-pick-head">
        <input type="search" class="icon-pick-search basic" data-pick-search
               placeholder="Search emoji or icons…" autocomplete="off"
               data-1p-ignore="true" data-lpignore="true">
        <button type="button" class="icon-pick-close" data-pick-close aria-label="Close">×</button>
      </div>
      <div class="icon-pick-grid" data-pick-grid></div>
      <div class="icon-pick-empty" data-pick-empty hidden>No matches.</div>
    </div>
  `;
  document.body.appendChild(el);

  const searchEl = el.querySelector("[data-pick-search]");
  const gridEl = el.querySelector("[data-pick-grid]");
  const emptyEl = el.querySelector("[data-pick-empty]");

  async function render() {
    const rows = await IconPool.search(searchEl.value, { limit: MAX_TILES });
    // An empty query is a "show everything" view, not "no matches" — the empty
    // state is reserved for a query that scored zero.
    const hasQuery = (searchEl.value || "").trim().length > 0;
    emptyEl.hidden = !hasQuery || rows.length > 0;

    const frag = document.createDocumentFragment();
    rows.forEach((row) => {
      const value = row._kind === "custom" ? `hicon:${row._id}` : row.c;
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "icon-pick-tile";
      btn.dataset.pickValue = value;
      btn.title = row.n || value;
      renderIconValue(btn, value);
      frag.appendChild(btn);
    });
    gridEl.replaceChildren(frag);
  }

  let searchTimer = null;
  searchEl.addEventListener("input", () => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(render, 100);
  });

  gridEl.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-pick-value]");
    if (!btn) return;
    const value = btn.dataset.pickValue;
    const cb = onPick;
    close();
    if (cb) cb(value);
  });

  el.querySelector("[data-pick-close]").addEventListener("click", close);
  // Only the backdrop itself — a click that started inside the sheet must not
  // dismiss it.
  el.addEventListener("click", (e) => {
    if (e.target === el) close();
  });

  el.__render = render;
  el.__search = searchEl;
  return el;
}

function onKeyDown(e) {
  if (e.key === "Escape") close();
}

export function close() {
  if (!modal || modal.hidden) return;
  modal.hidden = true;
  onPick = null;
  document.removeEventListener("keydown", onKeyDown);
}

export function openIconPicker({ onPick: cb, query = "" } = {}) {
  if (!modal) modal = buildModal();
  onPick = cb || null;
  modal.__search.value = query;
  modal.hidden = false;
  document.addEventListener("keydown", onKeyDown);
  modal.__render();
  // Deliberately NOT focused on touch: focusing a search field throws the
  // keyboard up over the grid, and the whole point of the grid is to browse it.
  if (!window.matchMedia("(pointer: coarse)").matches) modal.__search.focus();
}
