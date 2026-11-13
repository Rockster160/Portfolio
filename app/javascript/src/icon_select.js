// A dropdown whose options show their icons — the household's uploads and
// Tabler icons included, which a native <select> can only print as their
// reference ("hicon:12", "ti-flame").
//
// It dresses a real <select> rather than replacing it: the select stays in the
// form, hidden, and keeps holding the value, so whatever reads `.value` or
// listens for `change` carries on unchanged. Each <option> (and <optgroup>)
// names its icon in `data-icon`.
//
//   const wrap = iconSelect(selectEl);   // put `wrap` where the select was
//   selectEl.value = "b"; syncIconSelect(selectEl);   // after a code change

import { renderIconValue, onIconPoolChanged } from "./icon_picker";

let menu = null;
let menuFor = null;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text != null) node.textContent = text;
  return node;
}

function iconSlot(value) {
  const slot = el("span", "icon-select-icon");
  renderIconValue(slot, value || "");
  return slot;
}

function paint(select) {
  const button = select.__iconSelectButton;
  if (!button) return;
  const option = select.selectedOptions[0];
  button.replaceChildren(
    iconSlot(option?.dataset.icon),
    el("span", "icon-select-label", option ? option.textContent : ""),
    el("i", "ti ti-chevron-down icon-select-caret"),
  );
  button.disabled = select.disabled || select.options.length === 0;
}

function closeMenu() {
  if (!menu) return;
  menu.remove();
  menu = null;
  const select = menuFor;
  menuFor = null;
  select?.__iconSelectButton?.setAttribute("aria-expanded", "false");
}

function pick(select, value) {
  closeMenu();
  if (select.value === value) return;
  select.value = value;
  paint(select);
  select.dispatchEvent(new Event("change", { bubbles: true }));
}

function optionRow(select, option) {
  const row = el("button", "icon-select-option");
  row.type = "button";
  row.setAttribute("role", "option");
  row.dataset.value = option.value;
  if (option.selected) {
    row.classList.add("selected");
    row.setAttribute("aria-selected", "true");
  }
  row.append(iconSlot(option.dataset.icon), el("span", "icon-select-label", option.textContent));
  row.addEventListener("click", () => pick(select, option.value));
  return row;
}

// Fixed to the viewport so a scrolling modal can't clip it; opens upward when
// there's more room above the button than below.
function place(button) {
  const rect = button.getBoundingClientRect();
  const gap = 4;
  const below = window.innerHeight - rect.bottom - gap;
  const above = rect.top - gap;
  const up = below < 220 && above > below;
  const room = Math.max(120, (up ? above : below) - 8);
  menu.style.minWidth = `${rect.width}px`;
  menu.style.maxHeight = `${Math.min(room, 360)}px`;
  menu.style.left = `${Math.max(8, Math.min(rect.left, window.innerWidth - menu.offsetWidth - 8))}px`;
  if (up) menu.style.bottom = `${window.innerHeight - rect.top + gap}px`;
  else menu.style.top = `${rect.bottom + gap}px`;
}

function openMenu(select) {
  closeMenu();
  const button = select.__iconSelectButton;
  menu = el("div", "icon-select-menu");
  menu.setAttribute("role", "listbox");
  Array.from(select.children).forEach(child => {
    if (child.tagName === "OPTGROUP") {
      const head = el("div", "icon-select-group");
      head.append(iconSlot(child.dataset.icon), el("span", "icon-select-label", child.label));
      menu.appendChild(head);
      Array.from(child.children).forEach(option => menu.appendChild(optionRow(select, option)));
    } else if (child.tagName === "OPTION") {
      menu.appendChild(optionRow(select, child));
    }
  });
  document.body.appendChild(menu);
  menuFor = select;
  button.setAttribute("aria-expanded", "true");
  place(button);
  menu.querySelector(".selected")?.scrollIntoView({ block: "nearest" });
}

document.addEventListener("pointerdown", e => {
  if (!menu || menu.contains(e.target) || e.target.closest(".icon-select-button") === menuFor?.__iconSelectButton) return;
  closeMenu();
}, true);
document.addEventListener("keydown", e => { if (e.key === "Escape" && menu) { e.stopPropagation(); closeMenu(); } }, true);
document.addEventListener("scroll", e => { if (menu && !menu.contains(e.target)) closeMenu(); }, true);
window.addEventListener("resize", closeMenu);

// A household upload that arrives (or is deleted) after the page painted.
onIconPoolChanged(() => {
  document.querySelectorAll("select[data-icon-select]").forEach(paint);
});

export function iconSelect(select) {
  const wrap = el("span", "icon-select");
  const button = el("button", "icon-select-button");
  button.type = "button";
  button.setAttribute("aria-haspopup", "listbox");
  button.setAttribute("aria-expanded", "false");
  select.dataset.iconSelect = "";
  select.classList.add("icon-select-native");
  select.tabIndex = -1;
  select.__iconSelectButton = button;
  select.parentNode?.insertBefore(wrap, select);
  wrap.append(select, button);
  button.addEventListener("click", () => {
    if (menuFor === select) closeMenu();
    else openMenu(select);
  });
  select.addEventListener("change", () => paint(select));
  paint(select);
  return wrap;
}

export function syncIconSelect(select) {
  paint(select);
}
