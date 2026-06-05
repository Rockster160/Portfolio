// Library modal — searchable list of ALL templates (pinned + unpinned).
// Tapping one creates a new timer on the active page using the template
// (deep copy; instances are independent of the saved template).

import { defaultLabelForSeconds } from "./duration";

export function setupLibraryModal({ root, store, actions, activePageId }) {
  const dialog = root.querySelector("[data-timers-library-modal]");
  if (!dialog) return { open: () => {} };

  const search = dialog.querySelector("[data-timers-library-search]");
  const list = dialog.querySelector("[data-timers-library-list]");

  dialog.querySelectorAll("[data-timers-modal-close]").forEach((b) => {
    b.addEventListener("click", () => dialog.close());
  });

  function label(qb) {
    return qb.label || (qb.duration_seconds ? defaultLabelForSeconds(qb.duration_seconds) : "Timer");
  }

  function tag(qb) {
    const kind = qb.template?.kind || "countdown";
    const k = kind.charAt(0).toUpperCase() + kind.slice(1);
    if (kind === "countdown" && qb.duration_seconds) return `${k} · ${defaultLabelForSeconds(qb.duration_seconds)}`;
    return k;
  }

  function render() {
    const term = (search.value || "").toLowerCase().trim();
    const items = Array.from(store.quickButtons.values())
      .filter((qb) => {
        if (!term) return true;
        return label(qb).toLowerCase().includes(term) || tag(qb).toLowerCase().includes(term);
      })
      .sort((a, b) => label(a).localeCompare(label(b)));

    list.innerHTML = "";
    if (items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "timers-settings-empty";
      empty.textContent = term ? "No matches." : "No saved timers yet. Add some from Settings → Saved.";
      list.appendChild(empty);
      return;
    }

    items.forEach((qb) => {
      const row = document.createElement("button");
      row.type = "button";
      row.className = "timers-library-row";
      row.innerHTML = `
        <div class="row-body">
          <div class="label">${escapeHtml(label(qb))}</div>
          <div class="row-tag">${escapeHtml(tag(qb))}${qb.pinned ? " · pinned" : ""}</div>
        </div>
        <span class="row-action">+ Add</span>
      `;
      row.addEventListener("click", async () => {
        await addFromTemplate(qb);
        dialog.close();
      });
      list.appendChild(row);
    });
  }

  async function addFromTemplate(qb) {
    const template = qb.template && Object.keys(qb.template).length > 0
      ? qb.template
      : {
          kind: "countdown",
          duration_ms: (qb.duration_seconds || 300) * 1000,
          callbacks: [{ id: `cb-${Date.now()}`, event: "complete", type: "push" }],
        };
    const payload = { ...template, timer_page_id: activePageId() || null };
    const res = await actions.create(payload);
    if (res?.timer && res.timer.kind === "countdown") {
      await actions.start(res.timer.id);
    }
  }

  search.addEventListener("input", render);

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, (c) => (
      { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]
    ));
  }

  return {
    open() {
      search.value = "";
      render();
      dialog.showModal();
      requestAnimationFrame(() => search.focus());
    },
  };
}
