// One search box across every area: lists, chores, pages, timers, emails,
// stash, memories, contacts, inventory.
//
// Every `[data-global-search]` is wired the same way - the one in the overlay
// the layout carries, and the one on the /search page. Results come from
// `GET /search?q=` as JSON, already grouped and ranked by GlobalSearch.
//
//   [data-global-search]
//     input[data-global-search-input]
//     [data-global-search-results]
//
// The overlay opens on Cmd/Ctrl+K, on "/" when nothing is being typed in, and
// on a tap of anything marked `[data-global-search-open]`.

import { flatten, move, target, keyAction, opensOverlay } from "./nav.js";

const DEBOUNCE_MS = 150;
const ACTIVE = "is-active";

function escaped(text) {
  return String(text ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function iconClass(icon) {
  return `fa fa-${String(icon || "search").replace(/_/g, "-")}`;
}

function resultHtml(hit, index) {
  const subtitle = hit.subtitle ? `<span class="global-search-subtitle">${escaped(hit.subtitle)}</span>` : "";
  return `
    <a class="global-search-result" href="${escaped(hit.url)}" role="option"
       data-global-search-index="${index}">
      <i class="${iconClass(hit.icon)}" aria-hidden="true"></i>
      <span class="global-search-text">
        <span class="global-search-title">${escaped(hit.title)}</span>
        ${subtitle}
      </span>
    </a>`;
}

function groupsHtml(groups) {
  let index = 0;
  return groups.map((group) => {
    const rows = group.results.map((hit) => resultHtml(hit, index++)).join("");
    return `<div class="global-search-group"><div class="global-search-label">${escaped(group.label)}</div>${rows}</div>`;
  }).join("");
}

function setup(root, { onClose } = {}) {
  if (root.dataset.globalSearchWired) return null;
  root.dataset.globalSearchWired = "true";

  const input = root.querySelector("[data-global-search-input]");
  const results = root.querySelector("[data-global-search-results]");
  let hits = [];
  let active = -1;
  let timer = null;
  let sequence = 0;

  function highlight() {
    results.querySelectorAll("[data-global-search-index]").forEach((row) => {
      const on = Number(row.dataset.globalSearchIndex) === active;
      row.classList.toggle(ACTIVE, on);
      if (on) row.scrollIntoView({ block: "nearest" });
    });
  }

  function render(query, groups) {
    hits = flatten(groups);
    active = -1;
    if (!query) {
      results.innerHTML = "";
      results.hidden = true;
      return;
    }
    results.innerHTML = hits.length ? groupsHtml(groups) : `<div class="global-search-empty">Nothing found</div>`;
    results.hidden = false;
  }

  async function search(query) {
    const mine = ++sequence;
    if (!query) return render("", []);

    try {
      const res = await fetch(`/search?q=${encodeURIComponent(query)}`, {
        headers: { Accept: "application/json" },
        credentials: "same-origin",
      });
      if (!res.ok) throw new Error(`search ${res.status}`);
      const body = await res.json();
      if (mine === sequence) render(query, body.groups || []);
    } catch (_err) {
      if (mine === sequence) {
        results.innerHTML = `<div class="global-search-empty">Search failed</div>`;
        results.hidden = false;
      }
    }
  }

  input.addEventListener("input", () => {
    clearTimeout(timer);
    const query = input.value.trim();
    timer = setTimeout(() => search(query), DEBOUNCE_MS);
  });

  input.addEventListener("keydown", (event) => {
    const action = keyAction(event);
    if (!action) return;

    if (action === "down" || action === "up") {
      event.preventDefault();
      active = move(active, hits.length, action === "down" ? 1 : -1);
      highlight();
    } else if (action === "open") {
      const url = target(hits, active);
      if (!url) return;
      event.preventDefault();
      window.location.href = url;
    } else if (action === "close") {
      event.preventDefault();
      if (onClose) return onClose();
      input.value = "";
      render("", []);
    }
  });

  return {
    focus() {
      input.focus();
      input.select();
    },
    clear() {
      input.value = "";
      render("", []);
    },
  };
}

function isTyping(el) {
  if (!el) return false;
  return el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName);
}

function init() {
  const overlay = document.querySelector("[data-global-search-overlay]");
  let box = null;

  function close() {
    if (!overlay || overlay.hidden) return;
    overlay.hidden = true;
    box.clear();
    document.documentElement.classList.remove("global-search-open");
  }

  function open() {
    if (!overlay) return;
    overlay.hidden = false;
    document.documentElement.classList.add("global-search-open");
    box.focus();
  }

  if (overlay) {
    box = setup(overlay.querySelector("[data-global-search]"), { onClose: close });
    overlay.addEventListener("click", (event) => {
      if (event.target === overlay) close();
    });
    document.addEventListener("keydown", (event) => {
      if (!overlay.hidden) return;
      if (!opensOverlay(event, isTyping(document.activeElement))) return;
      event.preventDefault();
      open();
    });
    document.addEventListener("click", (event) => {
      if (!event.target.closest("[data-global-search-open]")) return;
      event.preventDefault();
      open();
    });
  }

  document.querySelectorAll("[data-global-search]").forEach((root) => {
    if (overlay?.contains(root)) return;
    const page = setup(root);
    if (page && root.hasAttribute("data-global-search-autofocus")) page.focus();
  });
}

if (typeof document !== "undefined") {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
}
