// A prompt's Search question: a box that looks records up as it is typed in,
// with the matches in a list underneath. Shared by the prompt page and the form
// Buddy posts in Byte, so both behave and look the same.
//
// What the question searches is fixed by the server (PromptSearch); every
// keystroke here only adds words to it. Results arrive as HTML the server drew
// from markdown: a one-line title, which is also what stays in the box once it
// is picked, and an optional detail beneath it.
//
// A pick is `{ id, title }`. With `free_text`, text matching nothing can be
// kept as `{ id: null, title }`. With `multiple`, the picks sit as chips ahead
// of the box and the value is a list.
//
// With `options`, the list to pick from is handed over instead of searched for
// on the server: each `{ id, title, icon, section }`, filtered as it's typed by
// the same scoring the chore pickers use. An `icon` is drawn ahead of the title
// the way it is everywhere else, and options sharing a `section` sit under it
// as a heading, which the search also matches.
//
// The list is in the flow, not floating: inside a message bubble a floating
// one is clipped by the bubble, and on a phone pushing the form down reads as
// the list opening rather than covering what is underneath.

import { score } from "./chore_search";
import { renderIconValue } from "./icon_picker";

const DEBOUNCE_MS = 140;

function escapeHtml(text) {
  const div = document.createElement("div");
  div.textContent = text == null ? "" : String(text);
  return div.innerHTML;
}

// A handed-over option as a result row: its icon drawn into the title.
function localHit(option) {
  const icon = document.createElement("span");
  icon.className = "psearch-icon";
  renderIconValue(icon, option.icon || "");
  const title = String(option.title || "");
  return {
    id: option.id,
    title,
    title_html: `${icon.childNodes.length ? icon.outerHTML : ""}${escapeHtml(title)}`,
    section: option.section || "",
  };
}

function filterLocal(hits, term) {
  if (!term) return hits;
  return hits.filter((hit) => score(term, hit.title, hit.section ? [hit.section] : []) > 0);
}

function picksOf(value) {
  const list = Array.isArray(value) ? value : value ? [value] : [];
  return list
    .filter((pick) => pick && (pick.id != null || String(pick.title || "").trim()))
    .map((pick) => ({
      id: pick.id == null || pick.id === "" ? null : pick.id,
      title: String(pick.title || ""),
      html: pick.html || escapeHtml(pick.title),
    }));
}

// Not <button>: the app's global button style forces white text and a blue
// fill with !important, and these sit inside a box of their own.
function control(className, label) {
  const el = document.createElement("span");
  el.className = className;
  el.setAttribute("role", "button");
  el.tabIndex = 0;
  if (label) el.setAttribute("aria-label", label);
  el.addEventListener("keydown", (evt) => {
    if (evt.key !== "Enter" && evt.key !== " ") return;
    evt.preventDefault();
    el.click();
  });
  return el;
}

function samePick(a, b) {
  if (a.id != null || b.id != null) return String(a.id) === String(b.id);
  return a.title.trim().toLowerCase() === b.title.trim().toLowerCase();
}

// `config`: { query, title, detail, multiple, free_text, placeholder }.
// `onChange` hears every change to the picks.
export function createSearchPicker({ config, value, disabled = false, onChange }) {
  const multiple = !!config.multiple;
  const freeText = !!config.free_text;
  const local = Array.isArray(config.options) ? config.options.map(localHit) : null;
  // A handed-over pick is known by its id alone; its title and icon come from
  // the option it names.
  const localPicks = (list) => {
    if (!local) return list;
    return list.map((pick) => {
      const hit = local.find((h) => String(h.id) === String(pick.id));
      return hit ? { id: hit.id, title: hit.title, html: hit.title_html } : pick;
    });
  };
  let picks = localPicks(picksOf(value));
  if (!multiple) picks = picks.slice(0, 1);

  let results = [];
  let active = -1;
  let open = false;
  let editing = false;
  let timer = null;
  let sequence = 0;

  const root = document.createElement("div");
  root.className = "psearch";
  root.dataset.multiple = multiple ? "true" : "false";
  if (disabled) root.classList.add("is-disabled");

  const box = document.createElement("div");
  box.className = "psearch-box";
  root.appendChild(box);

  const chips = document.createElement("div");
  chips.className = "psearch-chips";
  box.appendChild(chips);

  const picked = control("psearch-picked", "Search again");
  if (disabled) picked.tabIndex = -1;
  box.appendChild(picked);

  const input = document.createElement("input");
  input.type = "text";
  input.className = "psearch-input";
  input.autocomplete = "off";
  input.spellcheck = false;
  input.disabled = disabled;
  input.placeholder = config.placeholder || (multiple && picks.length ? "Add another…" : "Search…");
  input.setAttribute("role", "combobox");
  input.setAttribute("aria-autocomplete", "list");
  input.setAttribute("aria-expanded", "false");
  box.appendChild(input);

  const clear = control("psearch-clear", "Clear");
  clear.innerHTML = "&times;";
  box.appendChild(clear);

  const spinner = document.createElement("span");
  spinner.className = "psearch-spinner";
  spinner.setAttribute("aria-hidden", "true");
  box.appendChild(spinner);

  const menu = document.createElement("div");
  menu.className = "psearch-menu";
  menu.setAttribute("role", "listbox");
  root.appendChild(menu);

  function emit() {
    paint();
    onChange?.(read());
    root.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function read() {
    const clean = picks.map((pick) => ({ id: pick.id, title: pick.title }));
    return multiple ? clean : clean[0] || null;
  }

  // The single pick shows as its title in place of the box until it is tapped
  // to search again; a list shows its chips with the box after them.
  function paint() {
    const showPicked = !multiple && picks.length > 0 && !editing;
    root.classList.toggle("has-pick", picks.length > 0);
    picked.hidden = !showPicked;
    input.hidden = showPicked;
    picked.innerHTML = showPicked ? `<span class="psearch-title">${picks[0].html}</span>` : "";
    clear.hidden = disabled || !(showPicked || (editing && input.value));

    chips.hidden = !multiple || picks.length === 0;
    chips.innerHTML = "";
    if (multiple) {
      picks.forEach((pick, idx) => {
        const chip = document.createElement("span");
        chip.className = "psearch-chip";
        chip.innerHTML = `<span class="psearch-title">${pick.html}</span>`;
        if (!disabled) {
          const remove = control("psearch-chip-remove", `Remove ${pick.title}`);
          remove.innerHTML = "&times;";
          remove.addEventListener("mousedown", (evt) => evt.preventDefault());
          remove.addEventListener("click", () => {
            picks.splice(idx, 1);
            emit();
            input.focus();
          });
          chip.appendChild(remove);
        }
        chips.appendChild(chip);
      });
      input.placeholder = config.placeholder || (picks.length ? "Add another…" : "Search…");
    }
  }

  function setOpen(next) {
    open = next;
    root.classList.toggle("is-open", open);
    input.setAttribute("aria-expanded", open ? "true" : "false");
  }

  function renderMenu() {
    menu.innerHTML = "";
    const term = input.value.trim();
    const options = results.map((hit) => ({ hit }));
    const exact = results.some((hit) => hit.title.trim().toLowerCase() === term.toLowerCase());
    if (freeText && term && !exact) options.push({ free: term });
    if (active >= options.length) active = options.length - 1;

    if (!options.length) {
      const empty = document.createElement("div");
      empty.className = "psearch-empty";
      empty.textContent = root.classList.contains("is-loading") ? "Searching…" : "No matches";
      menu.appendChild(empty);
      return;
    }

    let section = "";
    options.forEach((option, idx) => {
      const heading = option.hit?.section || "";
      if (heading && heading !== section) {
        const head = document.createElement("div");
        head.className = "psearch-section";
        head.textContent = heading;
        menu.appendChild(head);
      }
      section = heading;
      const row = document.createElement("div");
      row.className = "psearch-option";
      row.setAttribute("role", "option");
      if (idx === active) row.classList.add("is-active");
      if (option.free) {
        row.classList.add("psearch-option-free");
        row.innerHTML = `<span class="psearch-title">Use “${escapeHtml(option.free)}”</span>`;
      } else {
        const hit = option.hit;
        const taken = picks.some((pick) => samePick(pick, { id: hit.id, title: hit.title }));
        row.classList.toggle("is-picked", taken);
        row.innerHTML =
          `<span class="psearch-title">${hit.title_html}</span>` +
          (hit.detail_html ? `<span class="psearch-detail">${hit.detail_html}</span>` : "");
      }
      // mousedown, not click: picking must happen before the box loses focus.
      row.addEventListener("mousedown", (evt) => {
        evt.preventDefault();
        choose(option);
      });
      menu.appendChild(row);
    });
  }

  function choose(option) {
    const pick = option.free
      ? { id: null, title: option.free, html: escapeHtml(option.free) }
      : { id: option.hit.id, title: option.hit.title, html: option.hit.title_html };

    if (multiple) {
      const at = picks.findIndex((p) => samePick(p, pick));
      if (at >= 0) picks.splice(at, 1);
      else picks.push(pick);
      input.value = "";
      emit();
      search();
      input.focus();
      return;
    }

    picks = [pick];
    input.value = "";
    editing = false;
    setOpen(false);
    emit();
    picked.focus();
  }

  async function search() {
    const mine = ++sequence;
    if (local) {
      results = filterLocal(local, input.value.trim());
      root.classList.remove("is-loading");
      active = results.length ? 0 : -1;
      if (open) renderMenu();
      return;
    }
    root.classList.add("is-loading");
    const params = new URLSearchParams({ query: config.query || "", term: input.value.trim() });
    if (config.title) params.set("title", config.title);
    if (config.detail) params.set("detail", config.detail);
    try {
      const res = await fetch(`/prompts/search?${params}`, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      const json = res.ok ? await res.json() : { results: [] };
      if (mine !== sequence) return;
      results = Array.isArray(json.results) ? json.results : [];
    } catch (e) {
      if (mine !== sequence) return;
      results = [];
    }
    root.classList.remove("is-loading");
    active = results.length ? 0 : freeText && input.value.trim() ? 0 : -1;
    if (open) renderMenu();
  }

  function queue() {
    clearTimeout(timer);
    if (local) {
      search();
      return;
    }
    root.classList.add("is-loading");
    timer = setTimeout(search, DEBOUNCE_MS);
  }

  function startEditing() {
    if (disabled) return;
    editing = true;
    paint();
    input.focus();
  }

  input.addEventListener("focus", () => {
    editing = true;
    setOpen(true);
    renderMenu();
    queue();
  });

  input.addEventListener("input", (evt) => {
    // The picker reports through `change`; a raw keystroke is not an answer.
    evt.stopPropagation();
    clear.hidden = !input.value;
    setOpen(true);
    queue();
  });

  input.addEventListener("keydown", (evt) => {
    const count = menu.querySelectorAll(".psearch-option").length;
    if (evt.key === "ArrowDown" || evt.key === "ArrowUp") {
      evt.preventDefault();
      if (!open) setOpen(true);
      if (count) active = (active + (evt.key === "ArrowDown" ? 1 : -1) + count) % count;
      renderMenu();
      menu.querySelector(".is-active")?.scrollIntoView({ block: "nearest" });
    } else if (evt.key === "Enter") {
      // Never submits the form underneath: Enter here means "this one".
      evt.preventDefault();
      const rows = menu.querySelectorAll(".psearch-option");
      if (open && active >= 0 && rows[active]) {
        rows[active].dispatchEvent(new MouseEvent("mousedown", { bubbles: true, cancelable: true }));
      }
    } else if (evt.key === "Escape") {
      setOpen(false);
      if (!multiple && picks.length) {
        input.value = "";
        editing = false;
        paint();
        picked.focus();
      }
    } else if (evt.key === "Backspace" && multiple && !input.value && picks.length) {
      picks.pop();
      emit();
    }
  });

  input.addEventListener("blur", () => {
    setTimeout(() => {
      if (root.contains(document.activeElement)) return;
      setOpen(false);
      const typed = input.value.trim();
      // Free text keeps what was left in the box, the way an autocomplete does.
      if (freeText && typed) {
        choose({ free: typed });
        return;
      }
      input.value = "";
      editing = false;
      paint();
    }, 0);
  });

  picked.addEventListener("click", startEditing);
  // A tap on the box itself, between its pieces, means "search".
  box.addEventListener("mousedown", (evt) => {
    if (evt.target !== box) return;
    evt.preventDefault();
    if (disabled) return;
    if (input.hidden) startEditing();
    else input.focus();
  });

  clear.addEventListener("mousedown", (evt) => evt.preventDefault());
  clear.addEventListener("click", () => {
    if (input.value) {
      input.value = "";
      queue();
      input.focus();
      return;
    }
    picks = [];
    emit();
    startEditing();
  });

  paint();

  root.searchPicker = {
    value: read,
    setValue(next) {
      picks = localPicks(picksOf(next));
      if (!multiple) picks = picks.slice(0, 1);
      paint();
    },
  };
  return root;
}

// The prompt page: each Search question renders a placeholder carrying its
// settings, and the answer posts through hidden inputs named the way Rails
// reads a hash, or a list of them.
function writeHidden(holder, name, value, multiple) {
  holder.innerHTML = "";
  const add = (key, val) => {
    const input = document.createElement("input");
    input.type = "hidden";
    input.name = key;
    input.value = val == null ? "" : String(val);
    holder.appendChild(input);
  };
  const list = multiple ? value || [] : value ? [value] : [];
  if (!list.length) return add(name, "");

  list.forEach((pick) => {
    const base = multiple ? `${name}[]` : name;
    add(`${base}[id]`, pick.id);
    add(`${base}[title]`, pick.title);
  });
}

function mountPage(el) {
  if (el.dataset.mounted) return;
  el.dataset.mounted = "true";

  let config = {};
  let value = null;
  try {
    config = JSON.parse(el.dataset.config || "{}");
    value = JSON.parse(el.dataset.value || "null");
  } catch (e) {
    console.warn("[prompt search] unreadable settings", e);
  }
  const holder = document.createElement("div");
  holder.className = "psearch-hidden";
  const name = el.dataset.name;
  const multiple = !!config.multiple;

  const picker = createSearchPicker({
    config,
    value,
    onChange: (next) => writeHidden(holder, name, next, multiple),
  });
  el.appendChild(picker);
  el.appendChild(holder);
  writeHidden(holder, name, picker.searchPicker.value(), multiple);
}

function mountAll() {
  document.querySelectorAll(".prompt-search-field").forEach(mountPage);
}

// Guarded so the Byte form, which imports the picker, still loads where there
// is no page to mount on.
if (typeof window !== "undefined" && typeof document.addEventListener === "function") {
  document.addEventListener("DOMContentLoaded", mountAll);
  window.addEventListener("load", mountAll);
}
