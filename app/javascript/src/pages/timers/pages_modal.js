// Pages modal — list of all pages with click-to-navigate + an inline
// "+ New page" form. Mirrors the Bookmarks/Library pattern so pages
// live in a header button instead of inline tabs. The list re-renders
// on any store change to pages, so adding a page from settings (or
// directly here) shows up immediately without a reload.

export function setupPagesModal({ root, store, actions, activePageSlug }) {
  const dialog = root.querySelector("[data-timers-pages-modal]");
  if (!dialog) return { open: () => {} };

  const list = dialog.querySelector("[data-timers-pages-modal-list]");
  const nameInput = dialog.querySelector("[data-timers-pages-modal-name]");
  const addBtn = dialog.querySelector("[data-timers-pages-modal-add]");

  dialog.querySelectorAll("[data-timers-modal-close]").forEach((b) => {
    b.addEventListener("click", () => dialog.close());
  });

  function render() {
    list.innerHTML = "";

    const home = pageRow({
      slug: null,
      name: "Home",
      tag: "/timers",
      active: !activePageSlug,
    });
    list.appendChild(home);

    const items = Array.from(store.pages.values())
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));
    items.forEach((p) => {
      list.appendChild(pageRow({
        slug: p.slug,
        name: p.name || p.slug,
        tag: `/timers/page/${p.slug}`,
        active: activePageSlug === p.slug,
      }));
    });
  }

  function pageRow({ slug, name, tag, active }) {
    const row = document.createElement("a");
    row.className = `timers-page-row ${active ? "active" : ""}`;
    row.href = slug ? `/timers/page/${encodeURIComponent(slug)}` : "/timers";
    row.innerHTML = `
      <div class="row-body">
        <div class="label">${escapeHtml(name)}</div>
        <div class="row-tag">${escapeHtml(tag)}</div>
      </div>
      ${active ? '<span class="row-flag">Current</span>' : ""}
    `;
    return row;
  }

  async function addPage() {
    const raw = nameInput.value.trim();
    if (!raw) return;
    const slug = raw.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || `page-${Date.now()}`;
    const res = await actions.createPage({ name: raw, slug });
    if (res?.slug) {
      // Navigate immediately so the user sees the new page.
      window.location.href = `/timers/page/${encodeURIComponent(res.slug)}`;
    }
  }

  addBtn.addEventListener("click", addPage);
  nameInput.addEventListener("keydown", (e) => {
    if (e.key === "Enter") { e.preventDefault(); addPage(); }
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
      dialog.showModal();
      requestAnimationFrame(() => nameInput.focus());
    },
  };
}
