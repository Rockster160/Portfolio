// Pages modal — every page with click-to-navigate. "New page" and "Add
// to this page" open the builder, its own modal: one line per timer in
// the quick_lines syntax, with a live readout of what each line makes,
// so a scoreboard for six players is one action instead of six trips
// through the new-timer modal.
//
// Page templates are pages: Duplicate copies a board — timers, quick
// buttons, page buttons — with counters back at their start value. Build
// the scoreboard once, copy it every game night. A page marked temporary
// is the throwaway version of the same thing: it carries a Temp flag so
// it's obvious which rows are safe to delete afterwards.

import { linesToTimers, previewLines, describeLine, displayName } from "./quick_lines";
import { ALL_COLORS } from "./colors";

export function setupPagesModal({ root, store, actions, activePageSlug, getActivePage }) {
  const dialog = root.querySelector("[data-timers-pages-modal]");
  if (!dialog) return { open: () => {} };

  const list    = dialog.querySelector("[data-timers-pages-modal-list]");
  const newBtn  = dialog.querySelector("[data-timers-pages-modal-new]");
  const hereBtn = dialog.querySelector("[data-timers-pages-modal-add-here]");
  const builder = setupBuilder({ root, store, actions, getActivePage });

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

  newBtn.addEventListener("click", () => { dialog.close(); builder.open({ toPage: null }); });
  hereBtn.addEventListener("click", () => { dialog.close(); builder.open({ toPage: getActivePage?.() }); });

  // Live re-render on any page change (added in settings, renamed,
  // deleted, etc.).
  store.subscribe((kind) => {
    if (kind === "page" || kind === "page_removed" || kind === "bootstrap" || kind === "sync") {
      if (dialog.open) render();
    }
  });

  return {
    open() {
      render();
      const page = getActivePage?.();
      hereBtn.classList.toggle("hidden", !page);
      if (page) hereBtn.textContent = `+ Add to ${page.name || page.slug}`;
      dialog.showModal();
    },
  };
}

function setupBuilder({ root, store, actions, getActivePage }) {
  const dialog = root.querySelector("[data-timers-builder-modal]");
  if (!dialog) return { open: () => {} };

  const titleEl   = dialog.querySelector("[data-timers-builder-title]");
  const nameInput = dialog.querySelector("[data-timers-builder-name]");
  const linesEl   = dialog.querySelector("[data-timers-builder-lines]");
  const preview   = dialog.querySelector("[data-timers-builder-preview]");
  const tempField = dialog.querySelector("[data-timers-builder-temp-field]");
  const tempInput = dialog.querySelector("[data-timers-builder-temp]");
  const submitBtn = dialog.querySelector("[data-timers-builder-submit]");

  // null = a new page; a page = adding to that one.
  let toPage = null;

  dialog.querySelectorAll("[data-timers-modal-close]").forEach((b) => {
    b.addEventListener("click", () => dialog.close());
  });

  function repaint() {
    // Dots wear the color each timer will get: its own, or the next one
    // round the palette, counting copies the way linesToTimers does.
    let slot = 0;
    preview.innerHTML = previewLines(linesEl.value).map((spec) => {
      const color = spec.color || ALL_COLORS[slot % ALL_COLORS.length];
      slot += spec.copies;
      return `
      <li>
        <span class="preview-dot" style="background:${escapeHtml(color)}"></span>
        <span class="preview-name">${escapeHtml(displayName(spec))}</span>
        <span class="preview-what">${escapeHtml(describeLine(spec))}</span>
      </li>
    `;
    }).join("");

    const count = linesToTimers(linesEl.value).length;
    const noun = count === 1 ? "timer" : "timers";
    if (toPage) {
      submitBtn.textContent = count ? `+ Add ${count} ${noun}` : "+ Add";
      submitBtn.disabled = count === 0;
    } else {
      submitBtn.textContent = count ? `+ Create page with ${count} ${noun}` : "+ Create page";
      submitBtn.disabled = nameInput.value.trim() === "";
    }
  }

  async function submit() {
    if (submitBtn.disabled) return;
    const timers = linesToTimers(linesEl.value);

    if (toPage) {
      submitBtn.disabled = true;
      await actions.bulkCreate(toPage.id, timers);
      linesEl.value = "";
      dialog.close();
      return;
    }

    const title = nameInput.value.trim();
    const slug = title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
    // Held disabled while the request is out, so a second tap can't send a
    // second page with the same slug.
    submitBtn.disabled = true;
    const page = await actions.createPage({
      name: title,
      slug: slug || `page-${store.pages.size + 1}`,
      meta: tempInput.checked ? { temporary: true } : {},
    });
    if (!page?.id) {
      repaint();
      alert(page?.__error ? `Couldn't create the page: ${page.__error}` : "Couldn't create the page.");
      return;
    }
    if (timers.length) await actions.bulkCreate(page.id, timers);
    // Navigate straight in — the page you just described is the one you
    // want to be looking at.
    window.location.href = `/timers/page/${encodeURIComponent(page.slug)}`;
  }

  [nameInput, linesEl].forEach((el) => el.addEventListener("input", repaint));
  submitBtn.addEventListener("click", submit);
  // Enter in the name box would submit the dialog's form and close it;
  // it moves on to the lines instead, where Enter is a new line.
  nameInput.addEventListener("keydown", (e) => {
    if (e.key !== "Enter") return;
    e.preventDefault();
    linesEl.focus();
  });
  // Cmd/Ctrl+Enter from the lines is the keyboard way to finish.
  linesEl.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) { e.preventDefault(); submit(); }
  });

  return {
    open({ toPage: target }) {
      toPage = target || null;
      titleEl.textContent = toPage ? `Add to ${toPage.name || toPage.slug}` : "New page";
      nameInput.classList.toggle("hidden", !!toPage);
      tempField.classList.toggle("hidden", !!toPage);
      repaint();
      dialog.showModal();
      requestAnimationFrame(() => (toPage ? linesEl : nameInput).focus());
    },
  };
}

function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
  ));
}
