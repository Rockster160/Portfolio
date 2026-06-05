// Settings modal — four tabs: Quick / Saved / Pages / Share. Quick rows
// have a drag handle for reorder; "Move to Saved" lives on the timer
// edit modal as "Save as template" instead. Saved rows have a
// "Pin to row" button to promote to Quick.

import Sortable from "../../../jil/Sortable.min.js";
import { defaultLabelForSeconds } from "./duration";

export function setupSettingsModal({ root, store, actions, getActivePage, openEdit }) {
  const dialog = root.querySelector("[data-timers-settings-modal]");
  if (!dialog) return { open: () => {} };

  const tabs = dialog.querySelectorAll("[data-timers-tab]");
  const panels = dialog.querySelectorAll("[data-timers-tab-panel]");
  const quickList = dialog.querySelector("[data-timers-quick-list]");
  const savedList = dialog.querySelector("[data-timers-saved-list]");
  const pagesList = dialog.querySelector("[data-timers-pages-list]");
  const shareEmpty = dialog.querySelector("[data-timers-share-empty]");
  const shareControls = dialog.querySelector("[data-timers-share-controls]");
  const shareList = dialog.querySelector("[data-timers-share-list]");
  const shareCreate = dialog.querySelector("[data-timers-share-create]");
  const shareMode = dialog.querySelector("[data-timers-share-mode]");
  const sharePageName = dialog.querySelector("[data-timers-share-page-name]");

  tabs.forEach((tab) => tab.addEventListener("click", () => activate(tab.dataset.timersTab)));
  dialog.querySelectorAll("[data-timers-modal-close]").forEach((b) => {
    b.addEventListener("click", () => dialog.close());
  });

  function activate(name) {
    tabs.forEach((t) => t.classList.toggle("active", t.dataset.timersTab === name));
    panels.forEach((p) => p.hidden = p.dataset.timersTabPanel !== name);
  }

  // -------- Quick / Saved (TimerQuickButton rows) ---------

  let quickSortable = null;

  function quickLabel(qb) {
    return qb.label || (qb.duration_seconds ? defaultLabelForSeconds(qb.duration_seconds) : "Quick button");
  }

  function quickTag(qb) {
    const kind = qb.template?.kind || "countdown";
    const k = kind.charAt(0).toUpperCase() + kind.slice(1);
    if (kind === "countdown" && qb.duration_seconds) return `${k} · ${defaultLabelForSeconds(qb.duration_seconds)}`;
    return k;
  }

  function quickRow(qb, { showHandle, pinToggleLabel }) {
    const row = document.createElement("div");
    row.className = showHandle ? "tmpl-row sortable" : "tmpl-row";
    row.dataset.quickId = qb.id;
    const handle = showHandle ? '<span class="row-handle" aria-hidden="true">⠿</span>' : '';
    const pinBtn = pinToggleLabel
      ? `<button type="button" data-action="pin-toggle">${pinToggleLabel}</button>`
      : "";
    row.innerHTML = `
      ${handle}
      <div class="row-body">
        <div class="label">${escapeHtml(quickLabel(qb))}</div>
        <div class="row-tag">${escapeHtml(quickTag(qb))}</div>
      </div>
      <div class="row-actions">
        ${pinBtn}
        <button type="button" data-action="edit">Edit</button>
        <button type="button" data-action="delete" class="danger">Delete</button>
      </div>
    `;
    row.querySelector('[data-action="edit"]').addEventListener("click", () => editQuick(qb));
    row.querySelector('[data-action="delete"]').addEventListener("click", async () => {
      if (!confirm(`Delete "${quickLabel(qb)}"?`)) return;
      await actions.destroyQuick(qb.id);
      renderQuickList();
      renderSavedList();
    });
    row.querySelector('[data-action="pin-toggle"]')?.addEventListener("click", async () => {
      await actions.updateQuick(qb.id, { pinned: !qb.pinned });
      renderQuickList();
      renderSavedList();
    });
    return row;
  }

  function renderQuickList() {
    quickList.innerHTML = "";
    const items = Array.from(store.quickButtons.values())
      .filter((qb) => qb.pinned !== false)
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));

    if (items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "timers-settings-empty";
      empty.textContent = "No quick buttons yet. Tap “+ New quick button” to add one.";
      quickList.appendChild(empty);
    }

    items.forEach((qb) => quickList.appendChild(quickRow(qb, { showHandle: true, pinToggleLabel: null })));

    quickSortable?.destroy();
    quickSortable = Sortable.create(quickList, {
      animation: 150,
      draggable: ".sortable",
      handle: ".row-handle",
      ghostClass: "row-ghost",
      forceFallback: true,
      fallbackOnBody: true,
      fallbackTolerance: 0,
      onEnd: async () => {
        const ids = Array.from(quickList.querySelectorAll(".sortable"))
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

  function renderSavedList() {
    savedList.innerHTML = "";
    const items = Array.from(store.quickButtons.values())
      .filter((qb) => qb.pinned === false)
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));

    if (items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "timers-settings-empty";
      empty.textContent = "No saved timers yet. Save any timer as a template from its Edit modal.";
      savedList.appendChild(empty);
      return;
    }
    items.forEach((qb) => savedList.appendChild(quickRow(qb, { showHandle: false, pinToggleLabel: "Pin to row" })));
  }

  function editQuick(qb) {
    openEdit({
      quick: {
        id: qb.id,
        label: qb.label,
        pinned: qb.pinned,
        duration_seconds: qb.duration_seconds,
        template: qb.template || {},
        onSave: async (payload) => {
          await actions.updateQuick(qb.id, payload);
          renderQuickList();
          renderSavedList();
        },
      },
    });
  }

  dialog.querySelector("[data-timers-add-quick]")?.addEventListener("click", () => openAdd({ pinned: true }));
  dialog.querySelector("[data-timers-add-saved]")?.addEventListener("click", () => openAdd({ pinned: false }));

  function openAdd({ pinned }) {
    openEdit({
      quick: {
        id: null,
        label: null,
        pinned: pinned,
        duration_seconds: 300,
        template: {},
        onSave: async (payload) => {
          const sort = (Array.from(store.quickButtons.values()).reduce((m, q) => Math.max(m, q.sort_order || 0), -1)) + 1;
          await actions.createQuick({ ...payload, sort_order: sort, pinned });
          renderQuickList();
          renderSavedList();
        },
      },
    });
  }

  // -------- Pages ---------

  function renderPagesList() {
    pagesList.innerHTML = "";
    const items = Array.from(store.pages.values())
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));

    if (items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "timers-settings-empty";
      empty.textContent = "No pages yet. Pages group timers into a separate view.";
      pagesList.appendChild(empty);
      return;
    }
    items.forEach((p) => {
      const row = document.createElement("div");
      row.className = "tmpl-row";
      row.innerHTML = `
        <span></span>
        <div class="row-body">
          <div class="label">${escapeHtml(p.name || p.slug)}</div>
          <div class="row-tag">/${escapeHtml(p.slug)}</div>
        </div>
        <div class="row-actions">
          <button type="button" data-action="rename">Rename</button>
          <button type="button" data-action="delete" class="danger">Delete</button>
        </div>
      `;
      row.querySelector('[data-action="rename"]').addEventListener("click", async () => {
        const name = prompt("Page name", p.name || "");
        if (name === null) return;
        await actions.updatePage(p.id, { name });
        renderPagesList();
      });
      row.querySelector('[data-action="delete"]').addEventListener("click", async () => {
        if (!confirm(`Delete page "${p.name || p.slug}"? Timers on this page move to Home.`)) return;
        await actions.destroyPage(p.id);
        renderPagesList();
        renderShareSection();
      });
      pagesList.appendChild(row);
    });
  }

  dialog.querySelector("[data-timers-add-page]")?.addEventListener("click", async () => {
    const input = dialog.querySelector("[data-timers-new-page-name]");
    const name = input.value.trim();
    if (!name) return;
    const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || `page-${Date.now()}`;
    await actions.createPage({ name, slug });
    input.value = "";
    renderPagesList();
  });

  // -------- Share ---------

  function renderShareSection() {
    const page = getActivePage();
    if (!page) {
      shareEmpty.hidden = false;
      shareControls.hidden = true;
      return;
    }
    shareEmpty.hidden = true;
    shareControls.hidden = false;
    sharePageName.textContent = page.name || page.slug;

    shareList.innerHTML = "";
    const tokens = (store.activeShareTokens || []).filter((s) => s.timer_page_id === page.id);
    if (tokens.length === 0) {
      const empty = document.createElement("div");
      empty.className = "timers-settings-empty";
      empty.textContent = "No active share links for this page.";
      shareList.appendChild(empty);
    }
    tokens.forEach((t) => {
      const row = document.createElement("div");
      row.className = "tmpl-row";
      const url = `${location.origin}/t/${t.token}`;
      row.innerHTML = `
        <span></span>
        <div class="row-body">
          <div class="label">${t.access_mode === "view_only" ? "View only" : "Interactive"}</div>
          <div class="row-tag"><code>${escapeHtml(url)}</code></div>
        </div>
        <div class="row-actions">
          <button type="button" data-action="copy">Copy</button>
          <button type="button" data-action="revoke" class="danger">Revoke</button>
        </div>
      `;
      row.querySelector('[data-action="copy"]').addEventListener("click", () => {
        navigator.clipboard?.writeText(url);
      });
      row.querySelector('[data-action="revoke"]').addEventListener("click", async () => {
        if (!confirm("Revoke this share link? Anyone using it will lose access immediately.")) return;
        await actions.destroyShare(t.id);
        store.activeShareTokens = (store.activeShareTokens || []).filter((s) => s.id !== t.id);
        renderShareSection();
      });
      shareList.appendChild(row);
    });
  }

  shareCreate?.addEventListener("click", async () => {
    const page = getActivePage();
    if (!page) return;
    const res = await actions.createShare({
      timer_page_id: page.id,
      access_mode: shareMode.value,
    });
    if (res?.id) {
      store.activeShareTokens = (store.activeShareTokens || []).concat([{
        id: res.id, token: res.token, timer_id: null, timer_page_id: page.id,
        access_mode: res.access_mode, url: res.url,
      }]);
      renderShareSection();
    }
  });

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
  }

  return {
    open(tab) {
      renderQuickList();
      renderSavedList();
      renderPagesList();
      renderShareSection();
      activate(tab || "quick");
      dialog.showModal();
    },
  };
}
