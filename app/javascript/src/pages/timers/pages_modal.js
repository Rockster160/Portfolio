// Pages modal — every page with click-to-navigate, plus the builder that
// makes one. The builder takes a LIST of names and creates a timer per
// line, so a scoreboard for six players is one action instead of six
// trips through the new-timer modal. Pointed at the page you're already
// on, the same list just adds to it (a seventh player showing up late).
//
// Page templates are pages: Duplicate copies a board — timers, quick
// buttons, page buttons — with counters back at their start value. Build
// the scoreboard once, copy it every game night. A page marked temporary
// is the throwaway version of the same thing: it carries a Temp flag so
// it's obvious which rows are safe to delete afterwards.

import { parseDuration, humanizeSeconds } from "./duration";
import { ALL_COLORS } from "./colors";

const DEFAULT_COUNTDOWN_SECONDS = 300;

// One name per line, or comma-separated on one — people type both.
export function parseNames(text) {
  return String(text || "")
    .split(/[\n,]/)
    .map((s) => s.trim())
    .filter(Boolean);
}

export function setupPagesModal({ root, store, actions, activePageSlug, getActivePage }) {
  const dialog = root.querySelector("[data-timers-pages-modal]");
  if (!dialog) return { open: () => {} };

  const list      = dialog.querySelector("[data-timers-pages-modal-list]");
  const targetSel = dialog.querySelector("[data-timers-pages-modal-target]");
  const nameField = dialog.querySelector("[data-timers-pages-modal-name-field]");
  const nameInput = dialog.querySelector("[data-timers-pages-modal-name]");
  const kindSel   = dialog.querySelector("[data-timers-pages-modal-kind]");
  const namesEl   = dialog.querySelector("[data-timers-pages-modal-names]");
  const argLabel  = dialog.querySelector("[data-timers-pages-modal-arg-label]");
  const argInput  = dialog.querySelector("[data-timers-pages-modal-arg]");
  const tempField = dialog.querySelector("[data-timers-pages-modal-temp-field]");
  const tempInput = dialog.querySelector("[data-timers-pages-modal-temp]");
  const addBtn    = dialog.querySelector("[data-timers-pages-modal-add]");
  const hint      = dialog.querySelector("[data-timers-pages-modal-hint]");

  dialog.querySelectorAll("[data-timers-modal-close]").forEach((b) => {
    b.addEventListener("click", () => dialog.close());
  });

  // -------- page list --------

  function render() {
    list.innerHTML = "";
    list.appendChild(pageRow({
      page:   null,
      name:   "Home",
      tag:    "/timers",
      href:   "/timers",
      active: !activePageSlug,
    }));

    Array.from(store.pages.values())
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0))
      .forEach((p) => {
        list.appendChild(pageRow({
          page:   p,
          name:   p.name || p.slug,
          tag:    `/timers/page/${p.slug}`,
          href:   `/timers/page/${encodeURIComponent(p.slug)}`,
          active: activePageSlug === p.slug,
        }));
      });
  }

  function pageRow({ page, name, tag, href, active }) {
    const row = document.createElement("div");
    row.className = `timers-page-row ${active ? "active" : ""}`;

    const link = document.createElement("a");
    link.className = "row-link";
    link.href = href;
    link.innerHTML = `
      <div class="row-body">
        <div class="label">${escapeHtml(name)}</div>
        <div class="row-tag">${escapeHtml(tag)}</div>
      </div>
      ${page?.meta?.temporary ? '<span class="row-flag row-flag-temp">Temp</span>' : ""}
      ${active ? '<span class="row-flag">Current</span>' : ""}
    `;
    row.appendChild(link);
    if (page) row.appendChild(rowActions(page, name));
    return row;
  }

  function rowActions(page, name) {
    const actionsEl = document.createElement("div");
    actionsEl.className = "row-actions";
    actionsEl.innerHTML = `
      <button type="button" data-action="duplicate" title="Copy this page and its timers">Duplicate</button>
      <button type="button" data-action="delete" class="danger" title="Delete this page">&times;</button>
    `;

    actionsEl.querySelector('[data-action="duplicate"]').addEventListener("click", async () => {
      const res = await actions.duplicatePage(page.id);
      if (res?.slug) window.location.href = `/timers/page/${encodeURIComponent(res.slug)}`;
    });
    actionsEl.querySelector('[data-action="delete"]').addEventListener("click", async () => {
      if (!confirm(`Delete page "${name}"? Timers on it move to Home.`)) return;
      await actions.destroyPage(page.id);
      if (activePageSlug === page.slug) { window.location.href = "/timers"; return; }
      render();
    });
    return actionsEl;
  }

  // -------- builder --------

  function addingToCurrentPage() {
    return targetSel.value === "current" && !!getActivePage?.();
  }

  function timerAttrs(name, index) {
    const color = ALL_COLORS[index % ALL_COLORS.length];
    if (kindSel.value === "countdown") {
      const seconds = parseDuration(argInput.value) || DEFAULT_COUNTDOWN_SECONDS;
      return {
        kind:        "countdown",
        name,
        color,
        duration_ms: seconds * 1000,
        callbacks:   [{
          id:   "cb-builder-sound",
          when: { type: "complete" },
          then: { type: "sound", chime: "soft", cadence: "once" },
        }],
      };
    }
    const start = parseInt(argInput.value, 10) || 0;
    return { kind: "counter", name, color, value: start, reset_value: start };
  }

  // The builder rewrites its own labels as you change what it's pointed
  // at — the same three fields mean different things for a countdown
  // page than for a scoreboard, and the button says what it will make.
  function repaintBuilder() {
    const page = getActivePage?.();
    targetSel.hidden = !page;
    if (!page && targetSel.value === "current") targetSel.value = "new";
    if (page) {
      targetSel.querySelector('option[value="current"]').textContent =
        `Add to ${page.name || page.slug}`;
    }

    const toCurrent = addingToCurrentPage();
    nameField.hidden = toCurrent;
    tempField.hidden = toCurrent;

    const countdown = kindSel.value === "countdown";
    argLabel.textContent = countdown ? "Each lasts" : "Each starts at";
    argInput.placeholder = countdown ? "5m" : "0";

    const names = parseNames(namesEl.value);
    const noun = names.length === 1 ? (countdown ? "timer" : "counter") : (countdown ? "timers" : "counters");
    if (toCurrent) {
      addBtn.textContent = names.length ? `+ Add ${names.length} ${noun}` : "+ Add";
      addBtn.disabled = names.length === 0;
    } else {
      addBtn.textContent = names.length ? `+ Create page with ${names.length} ${noun}` : "+ Create page";
      addBtn.disabled = nameInput.value.trim() === "";
    }

    hint.textContent = countdown
      ? `Each timer runs for ${humanizeSeconds(parseDuration(argInput.value) || DEFAULT_COUNTDOWN_SECONDS)}.`
      : "";
  }

  async function submitBuilder() {
    const names = parseNames(namesEl.value);
    const timers = names.map(timerAttrs);

    if (addingToCurrentPage()) {
      if (timers.length === 0) return;
      await actions.bulkCreate(getActivePage().id, timers);
      namesEl.value = "";
      dialog.close();
      return;
    }

    const title = nameInput.value.trim();
    if (!title) return;
    const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
    const page = await actions.createPage({
      name: title,
      slug: slug || `page-${store.pages.size + 1}`,
      meta: tempInput.checked ? { temporary: true } : {},
    });
    if (!page?.id) return;
    if (timers.length) await actions.bulkCreate(page.id, timers);
    // Navigate straight in — the page you just described is the one you
    // want to be looking at.
    window.location.href = `/timers/page/${encodeURIComponent(page.slug)}`;
  }

  [targetSel, kindSel].forEach((el) => el.addEventListener("change", repaintBuilder));
  [nameInput, namesEl, argInput].forEach((el) => el.addEventListener("input", repaintBuilder));
  addBtn.addEventListener("click", submitBuilder);
  // Enter anywhere but the names box submits; in the names box it's a
  // new line, which is the whole point of that field.
  [nameInput, argInput].forEach((el) => {
    el.addEventListener("keydown", (e) => {
      if (e.key === "Enter") { e.preventDefault(); submitBuilder(); }
    });
  });

  // Live re-render on any page change (added in settings, renamed,
  // deleted, etc.).
  store.subscribe((kind) => {
    if (kind === "page" || kind === "page_removed" || kind === "bootstrap" || kind === "sync") {
      if (dialog.open) render();
    }
  });

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
  }

  return {
    open() {
      render();
      repaintBuilder();
      dialog.showModal();
      requestAnimationFrame(() => (addingToCurrentPage() ? namesEl : nameInput).focus());
    },
  };
}
