import { IconPool } from "./icon_pool";

// ============================================================================
// Inline emoji / icon autocomplete for markdown composer inputs.
//
// Attach by adding class="emoji-autocomplete" to any <input> or <textarea>
// whose text is eventually rendered through the Markdown service. Typing
// `:` after start-of-input or any non-word char opens a floating popup;
// characters typed after the colon filter the pool live. Clicking a tile
// (or pressing Enter / Tab on a highlighted one) inserts the emoji glyph,
// `[hicon:ID]` (for household icons), or `[ticon:ti-*]` (for Tabler icons).
//
// Caret movement via keyboard arrows never RE-opens the popup — only
// typing or a mouse click into a valid `:word` context does. This keeps
// arrow nav (word skips, home/end, etc.) from producing surprise pops.
// ============================================================================

const POPUP_LIMIT = 8;
const POPUP_CLASS = "emoji-autocomplete-popup";

let popup = null;
let activeInput = null;
let activeTrigger = null; // { colonPos, endPos, query }
let lastQuery = null;     // last query passed to refreshResults — used to skip
                          // no-op refreshes that would reset the highlight
let results = [];
let highlightIndex = 0;
let searchToken = 0;

function ensurePopup() {
  if (popup) return popup;
  popup = document.createElement("div");
  popup.className = POPUP_CLASS + " hidden";
  popup.setAttribute("role", "listbox");
  popup.innerHTML = `
    <div class="emoji-autocomplete-tiles" data-tiles></div>
    <a class="emoji-autocomplete-manage" href="/chores/icons"
       title="Manage custom icons" tabindex="-1">
      <i class="fa fa-cog" aria-hidden="true"></i>
    </a>
    <div class="emoji-autocomplete-empty hidden" data-empty>No matches</div>
  `;
  // Ignore the popup's own mousedown so the underlying input keeps focus.
  popup.addEventListener("mousedown", (e) => { e.preventDefault(); });
  popup.addEventListener("click", onPopupClick);
  document.body.appendChild(popup);
  return popup;
}

function hidePopup() {
  if (!popup) return;
  popup.classList.add("hidden");
  activeInput = null;
  activeTrigger = null;
  lastQuery = null;
  results = [];
  highlightIndex = 0;
}

function detectTrigger(el) {
  const value = el.value;
  const caret = el.selectionStart;
  if (caret == null || caret !== el.selectionEnd) return null;

  // Only trigger when the caret is at the end of the token — the char
  // immediately after must be end-of-string or a non-word char. Editing
  // mid-word doesn't pop the picker.
  const nextCh = value[caret];
  if (nextCh != null && /\w/.test(nextCh)) return null;

  let colonPos = -1;
  for (let i = caret - 1; i >= 0; i--) {
    const ch = value[i];
    if (ch === ":") { colonPos = i; break; }
    if (!/\w/.test(ch)) return null;
  }
  if (colonPos < 0) return null;

  // Loose scope: colon can be preceded by any non-word char (including
  // punctuation like `(`, `[`, `-`). Only word chars block.
  if (colonPos > 0 && /\w/.test(value[colonPos - 1])) return null;

  return { colonPos: colonPos, endPos: caret, query: value.slice(colonPos + 1, caret) };
}

// Mirror-div caret positioning — works for both <input> and <textarea>.
// Returns viewport-relative { top, left, height } of the caret.
const MIRROR_STYLE_PROPS = [
  "direction", "boxSizing", "width", "height",
  "overflowX", "overflowY",
  "borderTopWidth", "borderRightWidth", "borderBottomWidth", "borderLeftWidth",
  "borderStyle",
  "paddingTop", "paddingRight", "paddingBottom", "paddingLeft",
  "fontStyle", "fontVariant", "fontWeight", "fontStretch", "fontSize",
  "fontSizeAdjust", "lineHeight", "fontFamily",
  "textAlign", "textTransform", "textIndent", "textDecoration",
  "letterSpacing", "wordSpacing", "tabSize",
];
function caretViewportCoords(el) {
  const isInput = el.tagName === "INPUT";
  const style = getComputedStyle(el);
  const div = document.createElement("div");
  MIRROR_STYLE_PROPS.forEach((p) => { div.style[p] = style[p]; });
  div.style.position = "absolute";
  div.style.visibility = "hidden";
  div.style.top = "0";
  div.style.left = "-9999px";
  div.style.whiteSpace = isInput ? "nowrap" : "pre-wrap";
  div.style.wordWrap = isInput ? "normal" : "break-word";

  let before = el.value.substring(0, el.selectionStart);
  if (isInput) before = before.replace(/\s/g, " ");
  div.textContent = before;

  const marker = document.createElement("span");
  marker.textContent = el.value.substring(el.selectionStart) || ".";
  div.appendChild(marker);
  document.body.appendChild(div);

  const rect = el.getBoundingClientRect();
  const lineHeight = parseInt(style.lineHeight, 10)
    || Math.round(parseInt(style.fontSize, 10) * 1.4);
  const coords = {
    top: rect.top + marker.offsetTop - el.scrollTop,
    left: rect.left + marker.offsetLeft - el.scrollLeft,
    height: lineHeight,
  };
  document.body.removeChild(div);
  return coords;
}

function positionPopup(el) {
  const c = caretViewportCoords(el);
  const rect = popup.getBoundingClientRect();
  const vw = window.innerWidth;
  const vh = window.innerHeight;
  let top = c.top + c.height + 4 + window.scrollY;
  let left = c.left + window.scrollX;
  if (c.left + rect.width > vw - 8) left = Math.max(8, vw - rect.width - 8) + window.scrollX;
  if (c.top + c.height + rect.height > vh - 8) top = c.top - rect.height - 4 + window.scrollY;
  popup.style.top = top + "px";
  popup.style.left = left + "px";
}

function buildTile(row, idx) {
  // Deliberately a <span> not a <button> — the global `button` cascade
  // in forms.scss:180 slaps on padding, gradient bg, white bold text,
  // and `!important` color. `all: unset` doesn't reliably strip it in
  // every browser. A span sidesteps the fight entirely.
  const btn = document.createElement("span");
  btn.className = "emoji-autocomplete-tile";
  btn.setAttribute("role", "option");
  btn.dataset.idx = String(idx);
  btn.title = row.n || "";
  if (row._kind === "custom") {
    btn.dataset.insert = "hicon:" + row._id;
    const img = document.createElement("img");
    img.src = row.c;
    img.alt = row.n || "";
    btn.appendChild(img);
  } else if (row._kind === "ti") {
    btn.dataset.insert = "ticon:" + row.c;
    const i = document.createElement("i");
    i.className = "ti " + row.c;
    btn.appendChild(i);
  } else {
    btn.dataset.insert = row.c;
    btn.textContent = row.c;
  }
  return btn;
}

function renderResults() {
  const tiles = popup.querySelector("[data-tiles]");
  const empty = popup.querySelector("[data-empty]");
  tiles.replaceChildren();
  results.forEach((row, idx) => tiles.appendChild(buildTile(row, idx)));
  const hasQuery = (activeTrigger?.query || "").length > 0;
  empty.classList.toggle("hidden", !(hasQuery && results.length === 0));
  applyHighlight();
}

function applyHighlight() {
  const tiles = popup.querySelectorAll(".emoji-autocomplete-tile");
  tiles.forEach((t, i) => t.classList.toggle("is-active", i === highlightIndex));
  const active = tiles[highlightIndex];
  if (active) active.scrollIntoView({ block: "nearest", inline: "nearest" });
}

async function refreshResults() {
  const q = activeTrigger?.query || "";
  if (q === lastQuery) return; // caret moved but query is unchanged — keep highlight
  lastQuery = q;
  const token = ++searchToken;
  const rows = await IconPool.search(q, { limit: POPUP_LIMIT });
  if (token !== searchToken) return;
  results = rows;
  highlightIndex = 0;
  renderResults();
}

function openFor(el, trigger) {
  ensurePopup();
  activeInput = el;
  activeTrigger = trigger;
  popup.classList.remove("hidden");
  positionPopup(el);
  refreshResults();
}

function insertValue(insert) {
  if (!activeInput || !activeTrigger) return;
  const el = activeInput;
  const { colonPos, endPos } = activeTrigger;
  const before = el.value.slice(0, colonPos);
  const after = el.value.slice(endPos);
  const rendered = wrapInsert(insert);
  el.value = before + rendered + after;
  const caret = colonPos + rendered.length;
  el.setSelectionRange(caret, caret);
  el.dispatchEvent(new Event("input", { bubbles: true }));
  hidePopup();
  el.focus();
}

function wrapInsert(insert) {
  if (insert.startsWith("hicon:")) return "[" + insert + "]";
  if (insert.startsWith("ticon:")) return "[" + insert + "]";
  return insert; // raw emoji glyph
}

function onPopupClick(e) {
  const tile = e.target.closest(".emoji-autocomplete-tile");
  if (tile) {
    insertValue(tile.dataset.insert);
    return;
  }
  // The manage link is a plain anchor — let it navigate normally.
}

// Runs on `input` and `click` — the two events allowed to (re-)open the
// popup. Both include cases where the user's intent is unambiguous:
// they typed a character, or they moved the caret with the mouse.
function evaluateAndMaybeOpen(el) {
  const trigger = detectTrigger(el);
  if (!trigger) { if (activeInput === el) hidePopup(); return; }
  openFor(el, trigger);
}

// Runs on caret-move keys and selectionchange — never opens the popup,
// only hides it when the caret leaves valid context.
function hideIfContextLost(el) {
  if (activeInput !== el) return;
  const trigger = detectTrigger(el);
  if (!trigger) { hidePopup(); return; }
  // Query drifted mid-word (arrow-left inside a token) — update it but
  // don't reopen a closed popup.
  activeTrigger = trigger;
  refreshResults();
}

function insertHighlighted() {
  const tiles = popup.querySelectorAll(".emoji-autocomplete-tile");
  const tile = tiles[highlightIndex];
  if (tile) insertValue(tile.dataset.insert);
}

function onKeydown(e) {
  const el = e.currentTarget;
  const isOpen = popup && !popup.classList.contains("hidden") && activeInput === el;
  if (!isOpen) return;
  switch (e.key) {
    case "ArrowRight":
    case "ArrowDown":
      e.preventDefault();
      if (results.length) {
        highlightIndex = (highlightIndex + 1) % results.length;
        applyHighlight();
      }
      break;
    case "ArrowLeft":
    case "ArrowUp":
      e.preventDefault();
      if (results.length) {
        highlightIndex = (highlightIndex - 1 + results.length) % results.length;
        applyHighlight();
      }
      break;
    case "Enter":
    case "Tab":
      if (!results.length) { hidePopup(); return; }
      e.preventDefault();
      insertHighlighted();
      break;
    case "Escape":
      e.preventDefault();
      hidePopup();
      break;
    default:
      break;
  }
}

function onCaretMoveKey(e) {
  const el = e.currentTarget;
  // Fires on keyup for arrow / navigation keys. We only ever HIDE from
  // here — never open — so arrow nav into a `:word` doesn't surprise-pop.
  const navKeys = ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown",
    "Home", "End", "PageUp", "PageDown"];
  if (!navKeys.includes(e.key)) return;
  hideIfContextLost(el);
}

function attach(el) {
  if (el.__emojiAutocompleteAttached) return;
  el.__emojiAutocompleteAttached = true;
  el.addEventListener("input", () => evaluateAndMaybeOpen(el));
  el.addEventListener("click", () => evaluateAndMaybeOpen(el));
  el.addEventListener("keydown", onKeydown);
  el.addEventListener("keyup", onCaretMoveKey);
  el.addEventListener("blur", () => {
    // Delay so a mousedown on a tile can fire first. mousedown on the
    // popup already preventDefaults focus loss, but blur can still fire
    // if the input was tabbed away.
    setTimeout(() => { if (activeInput === el) hidePopup(); }, 100);
  });
}

function scan(root) {
  const scope = root && root.querySelectorAll ? root : document;
  scope.querySelectorAll("input.emoji-autocomplete, textarea.emoji-autocomplete")
    .forEach(attach);
}

function init() {
  scan(document);
  // Warm the pool if any autocomplete inputs are on the page — first
  // keystroke shouldn't wait on the fetch.
  const hasAny = document.querySelector("input.emoji-autocomplete, textarea.emoji-autocomplete");
  if (hasAny) IconPool.load();

  // Hide when clicking outside the popup or active input.
  document.addEventListener("mousedown", (e) => {
    if (!popup || popup.classList.contains("hidden")) return;
    if (popup.contains(e.target)) return;
    if (e.target === activeInput) return;
    hidePopup();
  });

  // Late-added inputs (server-rendered fragments injected after load).
  // A MutationObserver keeps this hands-off for callers — just add the
  // class and it works.
  const mo = new MutationObserver((mutations) => {
    mutations.forEach((m) => {
      m.addedNodes.forEach((node) => {
        if (node.nodeType !== 1) return;
        if (node.matches?.("input.emoji-autocomplete, textarea.emoji-autocomplete")) {
          attach(node);
        } else if (node.querySelectorAll) {
          scan(node);
        }
      });
    });
  });
  mo.observe(document.body, { childList: true, subtree: true });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
