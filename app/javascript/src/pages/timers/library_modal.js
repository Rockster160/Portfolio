// Library modal — two tabs:
//   * Templates: GLOBAL saved templates (pinned=false, timer_page_id=null).
//                Drop onto any page; editable from anywhere.
//   * Quick:     PER-PAGE quick buttons (pinned=true, timer_page_id=active).
//                On Home, "active" === user defaults (timer_page_id=null),
//                which is also what the Settings cog manages globally.
//
// Both tabs are orderable (drag handle) and each row exposes Edit /
// Delete actions in addition to the existing tap-row-to-add behavior.

import Sortable from "../../../jil/Sortable.min.js";
import { defaultLabelForSeconds } from "./duration";

export function setupLibraryModal({ root, store, actions, activePageId, getActivePage, openEdit }) {
  const dialog = root.querySelector("[data-timers-library-modal]");
  if (!dialog) return { open: () => {} };

  const tabs = dialog.querySelectorAll("[data-timers-library-tab]");
  const panels = dialog.querySelectorAll("[data-timers-library-panel]");
  const search = dialog.querySelector("[data-timers-library-search]");
  const templatesList = dialog.querySelector("[data-timers-library-templates-list]");
  const quickList = dialog.querySelector("[data-timers-library-quick-list]");
  const quickBlurb = dialog.querySelector("[data-timers-library-quick-blurb]");

  let activeTab = "templates";
  let templatesSortable = null;
  let quickSortable = null;

  dialog.querySelectorAll("[data-timers-modal-close]").forEach((b) => {
    b.addEventListener("click", () => dialog.close());
  });

  tabs.forEach((tab) => tab.addEventListener("click", () => activate(tab.dataset.timersLibraryTab)));

  function activate(name) {
    activeTab = name;
    tabs.forEach((t) => t.classList.toggle("active", t.dataset.timersLibraryTab === name));
    panels.forEach((p) => p.hidden = p.dataset.timersLibraryPanel !== name);
    repaintActive();
  }

  function repaintActive() {
    if (activeTab === "templates") renderTemplates();
    else renderQuick();
  }

  function label(qb) {
    return qb.label || (qb.duration_seconds ? defaultLabelForSeconds(qb.duration_seconds) : "Timer");
  }

  function tag(qb) {
    const kind = qb.template?.kind || "countdown";
    const k = kind.charAt(0).toUpperCase() + kind.slice(1);
    if (kind === "countdown" && qb.duration_seconds) return `${k} · ${defaultLabelForSeconds(qb.duration_seconds)}`;
    return k;
  }

  function termMatches(qb, term) {
    if (!term) return true;
    return label(qb).toLowerCase().includes(term) || tag(qb).toLowerCase().includes(term);
  }

  function rowEl(qb) {
    const row = document.createElement("div");
    row.className = "tmpl-row sortable";
    row.dataset.quickId = qb.id;
    row.innerHTML = `
      <span class="row-handle" aria-hidden="true">⠿</span>
      <div class="row-body" data-action="add" role="button" tabindex="0">
        <div class="label">${escapeHtml(label(qb))}</div>
        <div class="row-tag">${escapeHtml(tag(qb))}</div>
      </div>
      <div class="row-actions">
        <button type="button" data-action="edit">Edit</button>
        <button type="button" data-action="delete" class="danger">Delete</button>
      </div>
    `;
    row.querySelector('[data-action="add"]').addEventListener("click", async () => {
      await addFromTemplate(qb);
      dialog.close();
    });
    row.querySelector('[data-action="edit"]').addEventListener("click", (e) => {
      e.stopPropagation();
      editQuick(qb);
    });
    row.querySelector('[data-action="delete"]').addEventListener("click", async (e) => {
      e.stopPropagation();
      if (!confirm(`Delete "${label(qb)}"?`)) return;
      await actions.destroyQuick(qb.id);
      repaintActive();
    });
    return row;
  }

  function renderList(listEl, items, emptyText) {
    listEl.innerHTML = "";
    if (items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "timers-settings-empty";
      empty.textContent = emptyText;
      listEl.appendChild(empty);
      return;
    }
    items.forEach((qb) => listEl.appendChild(rowEl(qb)));
  }

  function bindSortable(listEl, current) {
    current?.destroy();
    return Sortable.create(listEl, {
      animation: 150,
      draggable: ".sortable",
      handle: ".row-handle",
      ghostClass: "row-ghost",
      forceFallback: true,
      fallbackOnBody: true,
      fallbackTolerance: 0,
      onEnd: async () => {
        const ids = Array.from(listEl.querySelectorAll(".sortable"))
          .map((el) => parseInt(el.dataset.quickId, 10))
          .filter(Boolean);
        ids.forEach((id, i) => {
          const q = store.quickButtons.get(id);
          if (q) store.upsertQuick({ ...q, sort_order: i });
        });
        await actions.reorderQuick(ids);
      },
    });
  }

  function renderTemplates() {
    const term = (search.value || "").toLowerCase().trim();
    const items = Array.from(store.quickButtons.values())
      .filter((qb) => qb.pinned === false && !qb.timer_page_id)
      .filter((qb) => termMatches(qb, term))
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));

    renderList(
      templatesList,
      items,
      term ? "No matches." : "No templates yet. Save one from a timer's Edit modal or tap + New template.",
    );
    templatesSortable = bindSortable(templatesList, templatesSortable);
  }

  function renderQuick() {
    const pageId = activePageId();
    const page = getActivePage?.();
    const term = (search.value || "").toLowerCase().trim();
    const items = Array.from(store.quickButtons.values())
      .filter((qb) => qb.pinned === true && (pageId ? qb.timer_page_id === pageId : !qb.timer_page_id))
      .filter((qb) => termMatches(qb, term))
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));

    if (quickBlurb) {
      quickBlurb.textContent = page
        ? `Quick buttons on "${page.name || page.slug}". Drag to reorder.`
        : "Default quick buttons for Home. (Also manageable from Settings.)";
    }

    renderList(
      quickList,
      items,
      term ? "No matches." : "No quick buttons yet. Tap + New quick button to add one.",
    );
    quickSortable = bindSortable(quickList, quickSortable);
  }

  function editQuick(qb) {
    openEdit?.({
      quick: {
        id: qb.id,
        label: qb.label,
        pinned: qb.pinned,
        duration_seconds: qb.duration_seconds,
        template: qb.template || {},
        onSave: async (payload) => {
          const res = await actions.updateQuick(qb.id, payload);
          if (res?.__error) { alert(`Couldn't save: ${res.__error}`); return; }
          repaintActive();
        },
      },
    });
  }

  function addNewTemplate() {
    openEdit?.({
      quick: {
        id: null,
        label: null,
        pinned: false,
        duration_seconds: 300,
        template: {},
        onSave: async (payload) => {
          const sort = (Array.from(store.quickButtons.values())
            .filter((q) => q.pinned === false && !q.timer_page_id)
            .reduce((m, q) => Math.max(m, q.sort_order || 0), -1)) + 1;
          const res = await actions.createQuick({
            ...payload,
            sort_order:    sort,
            pinned:        false,
            timer_page_id: null,
          });
          if (res?.__error) { alert(`Couldn't save template: ${res.__error}`); return; }
          renderTemplates();
        },
      },
    });
  }

  function addNewQuick() {
    const pageId = activePageId();
    openEdit?.({
      quick: {
        id: null,
        label: null,
        pinned: true,
        duration_seconds: 300,
        template: {},
        onSave: async (payload) => {
          const sort = (Array.from(store.quickButtons.values())
            .filter((q) => q.pinned === true && (pageId ? q.timer_page_id === pageId : !q.timer_page_id))
            .reduce((m, q) => Math.max(m, q.sort_order || 0), -1)) + 1;
          const res = await actions.createQuick({
            ...payload,
            sort_order:    sort,
            pinned:        true,
            timer_page_id: pageId,
          });
          if (res?.__error) { alert(`Couldn't save: ${res.__error}`); return; }
          renderQuick();
        },
      },
    });
  }

  dialog.querySelector("[data-timers-library-add-template]")?.addEventListener("click", addNewTemplate);
  dialog.querySelector("[data-timers-library-add-quick]")?.addEventListener("click", addNewQuick);

  search.addEventListener("input", repaintActive);

  async function addFromTemplate(qb) {
    const template = qb.template && Object.keys(qb.template).length > 0
      ? qb.template
      : {
          kind: "countdown",
          duration_ms: (qb.duration_seconds || 300) * 1000,
          callbacks: [{ id: `cb-${Date.now()}`, event: "complete", type: "push" }],
        };
    const payload = { ...template, timer_page_id: activePageId() || null };
    if (!payload.color && qb.color) payload.color = qb.color;
    const res = await actions.create(payload);
    if (res?.timer && res.timer.kind === "countdown") {
      await actions.start(res.timer.id);
    }
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
  }

  return {
    open() {
      search.value = "";
      activate(activeTab);
      dialog.showModal();
      requestAnimationFrame(() => search.focus());
    },
  };
}
