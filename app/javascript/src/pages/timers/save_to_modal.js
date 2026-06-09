// "Save to…" picker. Replaces the old single-shot "Save as template"
// prompt: the user picks a destination (Templates / Page Quick Buttons
// / Default Quick Buttons), then either taps an existing row to replace
// its template or fills the bottom row to create a new one. The payload
// comes from the edit modal's readForm() snapshot so the saved record
// reflects whatever the user has currently configured.

import { defaultLabelForSeconds } from "./duration";

// Section definitions — each one knows how to filter the store's
// quickButtons for its slice + what to stamp on the persisted record.
//   pinned=false, timer_page_id=nil  → global saved templates
//   pinned=true,  timer_page_id=PAGE → that page's quick buttons
//   pinned=true,  timer_page_id=nil  → user defaults (Home pills)
function sectionDefs(activePageId) {
  return {
    templates: {
      label: "Templates",
      blurb: "Saved timer templates — open from any page via the Library.",
      empty: "No saved templates yet.",
      attrs: { pinned: false, timer_page_id: null },
      filter: (q) => q.pinned === false && !q.timer_page_id,
    },
    page: {
      label: "Page Quick Buttons",
      blurb: activePageId
        ? "Quick pills pinned to this page."
        : "Open a page to save quick buttons specific to it.",
      empty: "No page quick buttons yet.",
      attrs: { pinned: true, timer_page_id: activePageId || null },
      filter: (q) => q.pinned !== false && q.timer_page_id === activePageId,
      disabled: !activePageId,
    },
    defaults: {
      label: "Default Quick Buttons",
      blurb: "Quick pills shown on Home and seeded onto every new page.",
      empty: "No default quick buttons yet.",
      attrs: { pinned: true, timer_page_id: null },
      filter: (q) => q.pinned !== false && !q.timer_page_id,
    },
  };
}

export function setupSaveToModal({ root, store, actions, activePageId }) {
  const dialog = root.querySelector("[data-timers-saveto-modal]");
  if (!dialog) return { open: () => {} };

  const tabsEl = dialog.querySelectorAll("[data-timers-saveto-tab]");
  const blurbEl = dialog.querySelector("[data-timers-saveto-blurb]");
  const listEl = dialog.querySelector("[data-timers-saveto-list]");
  const labelInput = dialog.querySelector("[data-timers-saveto-new-label]");
  const createBtn = dialog.querySelector("[data-timers-saveto-create]");
  if (!blurbEl || !listEl || !labelInput || !createBtn) {
    return { open: () => {} };
  }

  let activeTab = "templates";
  let pendingPayload = null;   // latest readForm() snapshot from the edit modal.
  let activePage = null;       // captured per-open so the section attrs are stable.

  function defs() { return sectionDefs(activePage); }

  function quickLabel(qb) {
    return qb.label || (qb.duration_seconds ? defaultLabelForSeconds(qb.duration_seconds) : "Quick button");
  }

  function quickTag(qb) {
    const kind = qb.template?.kind || "countdown";
    const k = kind.charAt(0).toUpperCase() + kind.slice(1);
    if (kind === "countdown" && qb.duration_seconds) {
      return `${k} · ${defaultLabelForSeconds(qb.duration_seconds)}`;
    }
    return k;
  }

  function paint() {
    const def = defs()[activeTab];
    blurbEl.textContent = def.blurb;
    createBtn.disabled = !!def.disabled;
    labelInput.disabled = !!def.disabled;

    const items = Array.from(store.quickButtons.values())
      .filter(def.filter)
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));

    listEl.innerHTML = "";
    if (items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "timers-settings-empty";
      empty.textContent = def.empty;
      listEl.appendChild(empty);
      return;
    }

    items.forEach((qb) => {
      // Same row shape as settings/library modals (.tmpl-row + row-body/
      // row-tag). The WHOLE row is the click target — no per-row button.
      const row = document.createElement("div");
      row.className = "tmpl-row is-selectable";
      row.dataset.quickId = qb.id;
      row.innerHTML = `
        <div class="row-body">
          <div class="label">${esc(quickLabel(qb))}</div>
          <div class="row-tag">${esc(quickTag(qb))}</div>
        </div>
        <span class="tmpl-row-chevron" aria-hidden="true">›</span>
      `;
      row.addEventListener("click", () => overwrite(qb));
      listEl.appendChild(row);
    });
  }

  function activateTab(name) {
    activeTab = name;
    tabsEl.forEach((t) => t.classList.toggle("active", t.dataset.timersSavetoTab === name));
    paint();
  }

  async function overwrite(qb) {
    if (!pendingPayload) return;
    if (!confirm(`Replace "${quickLabel(qb)}" with the current settings?`)) return;
    const res = await actions.updateQuick(qb.id, {
      duration_seconds: secondsFromPayload(pendingPayload),
      color: pendingPayload.color,
      template: pendingPayload,
    });
    if (res?.__error) { alert(`Couldn't save: ${res.__error}`); return; }
    dialog.close();
  }

  async function createNew() {
    if (!pendingPayload) return;
    const def = defs()[activeTab];
    if (def.disabled) return;
    const seconds = secondsFromPayload(pendingPayload);
    const labelVal = labelInput.value.trim();
    const sortMax = Array.from(store.quickButtons.values())
      .filter(def.filter)
      .reduce((m, q) => Math.max(m, q.sort_order || 0), -1);

    const res = await actions.createQuick({
      ...def.attrs,
      label: labelVal || null,
      duration_seconds: seconds,
      color: pendingPayload.color,
      sort_order: sortMax + 1,
      template: pendingPayload,
    });
    if (res?.__error) { alert(`Couldn't save: ${res.__error}`); return; }
    dialog.close();
  }

  function secondsFromPayload(p) {
    return p.kind === "countdown" ? Math.round(p.duration_ms / 1000) : null;
  }

  function defaultLabelFromPayload(p) {
    const secs = secondsFromPayload(p);
    return p.name || (secs ? defaultLabelForSeconds(secs) : "Saved timer");
  }

  function esc(s) {
    return String(s).replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
  }

  tabsEl.forEach((t) =>
    t.addEventListener("click", () => activateTab(t.dataset.timersSavetoTab)),
  );
  createBtn.addEventListener("click", createNew);
  dialog.querySelectorAll("[data-timers-modal-close]").forEach((b) =>
    b.addEventListener("click", () => dialog.close()),
  );
  // Keep the list in sync if quickButtons mutate while the dialog is
  // open (e.g. a sibling tab broadcast adds a new row).
  store.subscribe((kind) => {
    if (!dialog.open) return;
    if (kind === "quick" || kind === "quick_removed" || kind === "sync" || kind === "bootstrap") {
      paint();
    }
  });

  function open(payload) {
    pendingPayload = payload;
    activePage = activePageId();
    labelInput.value = defaultLabelFromPayload(payload);
    activateTab(activePage ? "page" : "templates");
    dialog.showModal();
  }

  return { open };
}
