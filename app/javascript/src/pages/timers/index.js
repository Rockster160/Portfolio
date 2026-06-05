// Timers PWA entry. Boots on the owner page (data-timers-root) or the
// public share viewer (data-timers-share-root). No-ops on every other
// page — this module is bundled into application.js.

import { TimerStore } from "./store";
import { api } from "./api";
import { makeActions } from "./actions";
import { Board } from "./board";
import { IntervalTicker } from "./interval_ticker";
import { wireHeader, isMuted } from "./header";
import { setupEditModal } from "./edit_modal";
import { setupSettingsModal } from "./settings_modal";
import { setupLibraryModal } from "./library_modal";
import { setupPagesModal } from "./pages_modal";
import { setupCardMenu } from "./card_menu";
import { subscribeTimersChannel } from "./monitor";
import { flushQueue, saveStoreSnapshot, loadStoreSnapshot, lastSyncTs } from "./offline_queue";
import { defaultLabelForSeconds } from "./duration";
import { stopAllSounds } from "./audio";

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
}

function boot() {
  const ownerRoot = document.querySelector("[data-timers-root]");
  if (ownerRoot) bootOwner(ownerRoot);
  const shareRoot = document.querySelector("[data-timers-share-root]");
  if (shareRoot) bootShare(shareRoot);
}

function bootOwner(root) {
  const store = new TimerStore();
  const actions = makeActions({ api, store });

  // Bootstrap can come from a stale Service Worker shell cache (the
  // /timers HTML is cached on each fetch) — so we ALSO load the
  // localStorage snapshot, which is rewritten on every broadcast and
  // therefore reflects the most recent state the tab has seen. The
  // per-row `upsertTimer` timestamp check keeps the freshest source
  // per timer; if the snapshot is newer than the cached shell, the
  // snapshot's rows win.
  const bootstrap = readBootstrap("#timers-bootstrap");
  const cached = loadStoreSnapshot();
  if (bootstrap) {
    store.loadBootstrap(bootstrap);
  } else if (cached) {
    store.loadBootstrap({
      server_ts:           cached.last_sync_ts,
      timers:              cached.timers || [],
      pages:               cached.pages || [],
      quick_buttons:       cached.quick_buttons || [],
      active_share_tokens: [],
    });
  }
  if (bootstrap && cached) {
    // The cache overlay refreshes ROWS THE BOOTSTRAP ALSO HAS — never
    // re-adds rows the bootstrap omitted. Bootstrap is a snapshot at
    // server_ts; anything missing from it has been deleted server-side.
    // Skipping the existence check would let stale-but-deleted timers
    // resurrect themselves on every page load.
    const strictlyNewer = (c, e) => {
      const ct = Date.parse(c?.updated_at || 0);
      const et = Date.parse(e?.updated_at || 0);
      return Number.isFinite(ct) && Number.isFinite(et) && ct > et;
    };
    (cached.timers || []).forEach((t) => {
      const existing = store.timers.get(t.id);
      if (existing && strictlyNewer(t, existing)) store.upsertTimer(t, { silent: true });
    });
    (cached.pages || []).forEach((p) => {
      const existing = store.pages.get(p.id);
      if (existing && strictlyNewer(p, existing)) store.upsertPage(p);
    });
    (cached.quick_buttons || []).forEach((q) => {
      const existing = store.quickButtons.get(q.id);
      if (existing && strictlyNewer(q, existing)) store.upsertQuick(q);
    });
  }

  const activeSlug = root.dataset.activePageSlug || null;
  // Always pull from the store rather than capturing once at boot — the
  // page record can be updated via broadcast (e.g. a Jil task adding
  // page buttons), and downstream consumers like the buttons row need
  // to see those updates.
  const getActivePage = () => activeSlug
    ? Array.from(store.pages.values()).find((p) => p.slug === activeSlug)
    : null;
  const activePageId = () => getActivePage()?.id ?? null;

  const boardEl = root.querySelector("[data-timers-board]");
  const editModal = setupEditModal({ root, store, actions, activePageId });
  const settingsModal = setupSettingsModal({
    root, store, actions,
    getActivePage,
    openEdit: (ctx) => editModal.open(ctx),
  });
  const libraryModal = setupLibraryModal({ root, store, actions, activePageId });
  const pagesModal = setupPagesModal({ root, store, actions, activePageSlug: activeSlug });
  const cardMenu = setupCardMenu({
    root, store, actions,
    openEdit: (ctx) => editModal.open(ctx),
  });

  const board = new Board({
    root: boardEl,
    app: root,
    store,
    actions,
    getActivePageId: activePageId,
    onCardMenu: (id, btn) => cardMenu.open(id, btn),
  });
  board.renderAll();

  const ticker = new IntervalTicker({ store, board });

  wireHeader({ root, openSettings: () => settingsModal.open() });

  root.querySelector("[data-timers-new]")?.addEventListener("click", () => editModal.open());
  root.querySelector("[data-timers-library]")?.addEventListener("click", () => libraryModal.open());
  root.querySelector("[data-timers-pages]")?.addEventListener("click", () => pagesModal.open());
  wireEditToggle(root, board);
  wireQuickRow(root, store, actions, activePageId);
  wireQuickRowLive(root, store, actions, activePageId);
  wirePageButtons(root, store, getActivePage);

  try {
    // Sound is fully client-side; monitor only applies state diffs.
    // onReconnect runs one sync after a WS reopen to fill any gap.
    subscribeTimersChannel({
      store, api,
      onBeep: () => null,
      onSound: () => null,
      onReconnect: () => reconcile(),
    });
  } catch (e) {
    console.warn("Timers monitor failed:", e);
  }

  // Sync strategy — event-driven, NEVER periodic.
  //
  //   • Initial:           one delta sync after bootstrap (captures any
  //                        drift between when bootstrap was serialized
  //                        and when the page actually loaded).
  //   • Action-driven:     every mutation's response feeds the store,
  //                        so the actor tab is always live by definition.
  //   • Broadcast-driven:  MonitorChannel envelopes from other actors
  //                        trigger a delta sync (see monitor.js).
  //   • Visibility-driven: if the tab was hidden ≥ ~5s, a one-shot
  //                        sync runs on return — catches anything that
  //                        happened while the WS was suspended.
  //   • Reconnect-driven:  if the Monitor WS reconnects from a drop,
  //                        ONE sync runs to fill the gap.
  //
  // There is NO setInterval anywhere. Remaining-time is computed locally
  // from start/end/paused fields; the server is consulted only on real
  // state transitions, not on every UI tick.
  const reconcile = async () => {
    const diff = await api.sync(store.lastSyncTs || lastSyncTs());
    if (diff) store.applySync(diff);
    saveStoreSnapshot(store);
    await flushQueue({ csrfToken: csrfToken() });
  };
  reconcile();

  let hiddenAt = 0;
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") { hiddenAt = Date.now(); return; }
    const dt = hiddenAt ? Date.now() - hiddenAt : 0;
    hiddenAt = 0;
    if (dt < 5000) return; // ignore tiny flickers
    reconcile();
  });
  window.addEventListener("online", reconcile);
  window.addEventListener("beforeunload", () => {
    stopAllSounds();
    saveStoreSnapshot(store);
    ticker.destroy();
  });

  store.subscribe(() => saveStoreSnapshot(store));
}

function wireEditToggle(root, board) {
  const btn = root.querySelector("[data-timers-edit-toggle]");
  if (!btn) return;
  btn.addEventListener("click", () => {
    if (board.editMode) {
      board.exitEditMode();
      btn.classList.remove("is-active");
      btn.setAttribute("title", "Edit layout");
    } else {
      board.enterEditMode();
      btn.classList.add("is-active");
      btn.setAttribute("title", "Done editing");
    }
  });
}

// Reset the server-rendered quick row on every change to the store's
// quick buttons (pin/unpin, label edit, delete, reorder). The row only
// shows pinned templates; unpinned ones live in the Library modal.
function wireQuickRowLive(root, store, actions, activePageId) {
  function repaint() {
    let row = root.querySelector("[data-timers-quick-row]");
    const items = Array.from(store.quickButtons.values())
      .filter((qb) => qb.pinned !== false)
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));

    if (items.length === 0) {
      row?.remove();
      return;
    }

    if (!row) {
      row = document.createElement("section");
      row.className = "timers-quick-row";
      row.dataset.timersQuickRow = "";
      // Quick row lives between the header and the board now that page
      // tabs are gone. Insert before the toolbar / board.
      const header = root.querySelector(".timers-app-header");
      header?.insertAdjacentElement("afterend", row);
    }

    row.innerHTML = "";
    items.forEach((qb) => {
      const pill = document.createElement("button");
      pill.type = "button";
      pill.className = "timers-quick-pill";
      pill.dataset.quickId = qb.id;
      pill.textContent = qb.label || (qb.duration_seconds ? defaultLabelForSeconds(qb.duration_seconds) : "Quick");
      pill.addEventListener("click", () => addTimerFromQuick(qb, store, actions, activePageId));
      row.appendChild(pill);
    });
  }

  store.subscribe((kind) => {
    if (kind === "quick" || kind === "quick_removed" || kind === "bootstrap" || kind === "sync") repaint();
  });

  // Initial bind to any pre-rendered server pills — replace them with
  // JS-managed versions so subsequent clicks use the in-page template
  // and bypass the redirect.
  repaint();
}

// Page-level action buttons: a row of links rendered above the quick
// pills, one per TimerPageButton on the active page. Each button is a
// generic outbound link — typically pointing at a Jil page/form task
// (`/jil/p/:id` / `/jil/f/:id`) but the model has no opinion, so
// users can wire any URL they want.
function wirePageButtons(root, store, getActivePage) {
  function repaint() {
    const page = getActivePage();
    const buttons = (page?.buttons || [])
      .slice()
      .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));

    let row = root.querySelector("[data-timers-page-buttons]");
    if (buttons.length === 0) { row?.remove(); return; }

    if (!row) {
      row = document.createElement("section");
      row.className = "timers-page-buttons";
      row.dataset.timersPageButtons = "";
      // Sits BELOW the quick-add row, ABOVE the timer board. Quick row
      // is only rendered when there are pinned quicks, so fall back to
      // the header when it's absent.
      const anchor = root.querySelector("[data-timers-quick-row]")
        || root.querySelector(".timers-app-header");
      anchor?.insertAdjacentElement("afterend", row);
    }
    row.innerHTML = "";
    buttons.forEach((b) => {
      const a = document.createElement("a");
      a.className = "timers-page-button";
      a.href = b.target_url || "#";
      if (b.color) a.style.setProperty("--button-color", b.color);
      a.textContent = b.label || b.target_url || "Button";
      row.appendChild(a);
    });
  }

  store.subscribe((kind) => {
    if (kind === "bootstrap" || kind === "sync" || kind === "page" || kind === "page_removed") repaint();
  });
  repaint();
}

async function addTimerFromQuick(qb, store, actions, activePageId) {
  const template = qb.template && Object.keys(qb.template).length > 0
    ? qb.template
    : {
        kind: "countdown",
        duration_ms: (qb.duration_seconds || 60) * 1000,
        name: qb.label || "",
        callbacks: [{ id: `cb-${Date.now()}`, event: "complete", type: "push" }],
      };
  const payload = { ...template, timer_page_id: activePageId() || null };
  const res = await actions.create(payload);
  if (res?.timer && res.timer.kind === "countdown") {
    await actions.start(res.timer.id);
  }
}

function wireQuickRow(root, store, actions, activePageId) {
  // Server-rendered forms: intercept before they POST so we go through
  // the JS action layer instead of a full redirect.
  root.querySelectorAll("[data-timers-quick-form]").forEach((form) => {
    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      const qbId = parseInt(form.dataset.quickId, 10);
      const qb = store.quickButtons.get(qbId);
      if (qb) await addTimerFromQuick(qb, store, actions, activePageId);
    });
  });
}

function readBootstrap(selector) {
  const el = document.querySelector(selector);
  if (!el) return null;
  try { return JSON.parse(el.textContent || "{}"); }
  catch (e) { return null; }
}

function bootShare(root) {
  const data = readBootstrap("#timers-share-bootstrap");
  if (!data) return;
  const store = new TimerStore();
  (data.timers || []).forEach((t) => store.upsertTimer(t, { silent: true }));
  if (data.page) store.upsertPage(data.page);

  const boardEl = root.querySelector("[data-timers-board]");
  const shareMode = root.dataset.shareMode;
  const token = root.dataset.shareToken;
  const interactive = shareMode === "interactive";
  const shareActions = makeShareActions(token, interactive, store);

  const board = new Board({
    root: boardEl,
    app: root,
    store,
    actions: shareActions,
    getActivePageId: () => data.page?.id ?? null,
    onCardMenu: () => {},
  });
  board.renderAll();
  new IntervalTicker({ store, board });

  setInterval(async () => {
    try {
      const res = await fetch(`/t/${token}/sync`, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      if (res.status === 410) {
        document.body.innerHTML = "<div style='padding:40px;text-align:center;color:#fff;background:#0d1117;'>This share link has been revoked.</div>";
        return;
      }
      if (!res.ok) return;
      const json = await res.json();
      (json.timers || []).forEach((t) => store.upsertTimer(t, { silent: true }));
      store.notify("sync", { diff: json });
    } catch (e) { /* ignore */ }
  }, 2000);
}

function makeShareActions(token, interactive, store) {
  async function post(path, body) {
    if (!interactive) return null;
    const res = await fetch(`/t/${token}/${path}`, {
      method: "POST",
      credentials: "same-origin",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify(body || {}),
    });
    if (!res.ok) return null;
    return await res.json();
  }
  function apply(res) { if (res?.timer) store.upsertTimer(res.timer); return res; }
  return {
    start:     async (id) => apply(await post("start", { timer_id: id })),
    pause:     async (id) => apply(await post("pause", { timer_id: id })),
    resume:    async (id) => apply(await post("resume", { timer_id: id })),
    reset:     async (id) => apply(await post("reset", { timer_id: id })),
    confirm:   async (id) => apply(await post("confirm", { timer_id: id })),
    increment: async (id, by) => apply(await post("increment", { timer_id: id, by })),
    advance:   async (id, by) => apply(await post("advance", { timer_id: id, by })),
    reorder:   () => null,
  };
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot);
} else {
  boot();
}
