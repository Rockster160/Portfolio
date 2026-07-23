// Byte chat page. Ties together:
//   * The offline outbound queue (queue.js + api.js) so sends work even
//     with no reception and drain FIFO when it comes back.
//   * localStorage-cached message history (store.js) so cold-open /
//     no-network still renders the last conversation.
//   * Realtime updates via MonitorChannel — same rail used by chores,
//     agenda, timers.
//   * The byte service worker (shell_sync.js) — shell caching and a
//     "syncing" badge in the header.
//   * Push notifications (push.js).
//
// Never redraws the whole thread — every update is a granular upsert
// keyed by message id (or `local_id` for pre-server queued sends), per
// the no-DOM-redraw-on-sync rule.

import { Monitor } from "../dashboard/cells/monitor";
import { loadMessages, upsertPersisted } from "./store";
import { all as allQueued } from "./queue";
import { configure as configureApi, sendMessage, drainQueue } from "./api";
import {
  registerServiceWorker,
  onShellSync,
  requestShellRefresh,
} from "./shell_sync";
import {
  ensureByteServiceWorker,
  checkByteNotificationStatus,
  registerByteNotifications,
  unregisterByteNotifications,
} from "./push";

document.addEventListener("DOMContentLoaded", async () => {
  const app = document.querySelector(".byte-app");
  if (!app) return;

  // ---------- DOM refs ----------
  const thread    = app.querySelector("[data-byte-thread]");
  const loader    = app.querySelector("[data-byte-loader]");
  const composer  = app.querySelector("[data-byte-composer]");
  const input     = app.querySelector("[data-byte-input]");
  const status    = app.querySelector("[data-byte-status]");
  const syncBadge = app.querySelector("[data-byte-sync]");
  const notifyBtn = app.querySelector("[data-byte-notify]");
  const jumpBtn   = app.querySelector("[data-byte-jump]");
  const jumpCount = app.querySelector("[data-byte-jump-count]");
  const tpl       = app.querySelector("[data-byte-message-tpl]");

  const sendUrl        = app.dataset.sendUrl;
  const messagesUrl    = app.dataset.messagesUrl;
  const csrfUrl        = app.dataset.csrfUrl || "/byte/csrf";
  const monitorChannel = app.dataset.monitorChannel;

  configureApi({ sendUrl, csrfRefreshUrl: csrfUrl });

  // ---------- state ----------
  let messages = loadMessages(); // instant offline render source

  // Fold in the server-rendered bootstrap (fresh at page-load time).
  loadBootstrap().forEach((m) => {
    messages = upsertPersisted(messages, m);
  });

  // Scroll / unread bookkeeping. `atBottom` starts true — a fresh open
  // wants to land pinned at newest. `hasMore` is optimistically true so
  // the first scroll-to-top triggers a fetch; the server flips it to
  // false once we've reached the head of the archive.
  const NEAR_BOTTOM_PX = 60;
  const LOAD_TRIGGER_PX = 200;
  let atBottom      = true;
  let unreadCount   = 0;
  let hasMore       = true;
  let loadingOlder  = false;
  let oldestLoadedId = messages[0]?.id ?? null;

  // ---------- rendering primitives ----------

  const timeFmt = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

  function formatTime(iso) {
    if (!iso) return "";
    try { return timeFmt.format(new Date(iso)); } catch { return ""; }
  }

  function cssEscape(s) {
    return (typeof CSS !== "undefined" && CSS.escape) ? CSS.escape(s) : s.replace(/"/g, '\\"');
  }

  function selectorForId(id)        { return `[data-message-id="${cssEscape(String(id))}"]`; }
  function selectorForLocal(local)  { return `[data-local-id="${cssEscape(String(local))}"]`; }

  function nodeForServerMessage(message) {
    // Server response for a queued send carries our client-assigned
    // metadata.local_id, so we upgrade the queued bubble in place instead
    // of appending a duplicate.
    const localId = message?.metadata?.local_id;
    if (localId) {
      const local = thread.querySelector(selectorForLocal(localId));
      if (local) return local;
    }
    return thread.querySelector(selectorForId(message.id));
  }

  function newMessageNode() {
    return tpl.content.firstElementChild.cloneNode(true);
  }

  function paintMessageNode(node, message) {
    node.dataset.messageId = String(message.id);
    if (message?.metadata?.local_id) node.dataset.localId = String(message.metadata.local_id);
    node.className = [
      "byte-msg",
      `byte-msg-${message.direction}`,
      `byte-msg-${message.state}`,
    ].join(" ");
    node.querySelector("[data-body]").textContent = message.body || "";
    node.querySelector("[data-time]").textContent = formatTime(message.created_at);
    renderAttachments(node.querySelector("[data-attachments]"), message.attachments);
    node.querySelector("[data-state]").textContent = renderState(message);
  }

  // Upsert a server-persisted message. Uses append-at-end for new nodes
  // (bottom-anchored layout keeps them visually beneath the last one).
  function upsertMessage(message) {
    let node = nodeForServerMessage(message);
    if (!node) {
      node = newMessageNode();
      thread.appendChild(node);
    }
    paintMessageNode(node, message);
  }

  function upsertQueuedMessage(entry) {
    let node = thread.querySelector(selectorForLocal(entry.local_id));
    if (!node) {
      node = newMessageNode();
      thread.appendChild(node);
    }
    node.dataset.localId = String(entry.local_id);
    node.removeAttribute("data-message-id");
    node.className = "byte-msg byte-msg-outbound byte-msg-queued";
    node.querySelector("[data-body]").textContent = entry.body || "";
    node.querySelector("[data-time]").textContent = formatTime(new Date(entry.queued_at).toISOString());
    renderAttachments(node.querySelector("[data-attachments]"), []);
    node.querySelector("[data-state]").textContent = "queued";
  }

  function markQueuedSending(local_id) {
    const node = thread.querySelector(selectorForLocal(local_id));
    if (!node) return;
    node.classList.remove("byte-msg-queued", "byte-msg-failed");
    node.classList.add("byte-msg-pending");
    node.querySelector("[data-state]").textContent = "…";
  }

  function markQueuedFailed(local_id, reason) {
    const node = thread.querySelector(selectorForLocal(local_id));
    if (!node) return;
    node.classList.remove("byte-msg-pending", "byte-msg-queued");
    node.classList.add("byte-msg-failed");
    node.querySelector("[data-state]").textContent = `failed: ${reason}`;
  }

  function renderAttachments(container, attachments) {
    if (!container) return;
    const list = Array.isArray(attachments) ? attachments : [];
    const currentIds = Array.from(container.children).map((el) => el.dataset.attachmentId);
    const nextIds = list.map((a) => String(a.id));
    if (currentIds.join(",") === nextIds.join(",")) return;

    container.innerHTML = "";
    list.forEach((a) => container.appendChild(buildAttachment(a)));
  }

  function buildAttachment(a) {
    const wrap = document.createElement("div");
    wrap.className = "byte-attachment";
    wrap.dataset.attachmentId = String(a.id);
    wrap.dataset.contentType = a.content_type || "";

    const type = (a.content_type || "").split("/")[0];
    if (type === "image") {
      const img = document.createElement("img");
      img.src = a.url; img.alt = a.filename || ""; img.loading = "lazy";
      wrap.appendChild(img);
    } else if (type === "audio") {
      const audio = document.createElement("audio");
      audio.src = a.url; audio.controls = true;
      wrap.appendChild(audio);
    } else if (type === "video") {
      const video = document.createElement("video");
      video.src = a.url; video.controls = true; video.playsInline = true;
      wrap.appendChild(video);
    } else {
      const link = document.createElement("a");
      link.href = a.url;
      link.textContent = a.filename || "file";
      link.download = a.filename || "";
      link.rel = "noopener"; link.target = "_blank";
      wrap.appendChild(link);
    }
    return wrap;
  }

  function renderState(message) {
    if (message.state === "streaming") return "";
    if (message.direction !== "outbound") return "";
    if (message.state === "pending") return "…";
    if (message.state === "failed") return "failed";
    return "";
  }

  // ---------- scroll / jump-button / atBottom bookkeeping ----------

  function measureAtBottom() {
    const gap = thread.scrollHeight - thread.scrollTop - thread.clientHeight;
    return gap < NEAR_BOTTOM_PX;
  }

  function scrollToBottom(behavior = "auto") {
    // scrollTop can slightly overshoot from browser rounding — set to a
    // large value; the browser clamps it to the max valid position.
    thread.scrollTo({ top: thread.scrollHeight + 4096, behavior });
    atBottom = true;
    clearUnread();
  }

  function clearUnread() {
    unreadCount = 0;
    updateJumpBtn();
  }

  function updateJumpBtn() {
    if (!jumpBtn) return;
    const shouldShow = !atBottom;
    jumpBtn.classList.toggle("visible", shouldShow);
    if (jumpCount) jumpCount.textContent = unreadCount > 0 ? String(unreadCount) : "";
  }

  jumpBtn?.addEventListener("click", () => scrollToBottom("smooth"));

  thread.addEventListener("scroll", () => {
    atBottom = measureAtBottom();
    if (atBottom) clearUnread();
    updateJumpBtn();
    if (thread.scrollTop < LOAD_TRIGGER_PX) maybeLoadOlder();
  });

  // Route incoming (server-broadcast) messages: outbound-user-sent from
  // this device always scrolls; anything else respects atBottom.
  function receiveMessage(message, { forceScroll = false } = {}) {
    const wasAtBottom = atBottom;
    const isMine = message.direction === "outbound";
    upsertMessage(message);

    if (forceScroll || isMine || wasAtBottom) {
      // Wait one frame for the appended node to lay out so the scroll
      // target is the new scrollHeight, not the pre-append one.
      requestAnimationFrame(() => scrollToBottom(wasAtBottom ? "smooth" : "auto"));
    } else {
      unreadCount += 1;
      updateJumpBtn();
    }
  }

  // ---------- pagination (scroll-to-top loads older) ----------

  function setLoader(state) {
    if (!loader) return;
    if (state === "loading") {
      loader.hidden = false;
      loader.textContent = "loading…";
    } else if (state === "end") {
      loader.hidden = false;
      loader.textContent = "no more messages";
      setTimeout(() => { loader.hidden = true; }, 1500);
    } else {
      loader.hidden = true;
    }
  }

  async function maybeLoadOlder() {
    if (loadingOlder || !hasMore || !messagesUrl) return;
    if (!oldestLoadedId) return; // no anchor yet — server bootstrap will set it
    if (!navigator.onLine) return;

    loadingOlder = true;
    setLoader("loading");

    // Preserve visual position: after prepending, we'll set scrollTop so
    // the same message the user was looking at stays put.
    const prevHeight = thread.scrollHeight;
    const prevScroll = thread.scrollTop;

    try {
      const url = new URL(messagesUrl, location.href);
      url.searchParams.set("before", String(oldestLoadedId));
      const res = await fetch(url.toString(), {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return;
      const payload = await res.json();
      const older = Array.isArray(payload.messages) ? payload.messages : [];
      hasMore = !!payload.has_more;

      if (older.length === 0) {
        setLoader("end");
        return;
      }

      // Server returns chronologically (oldest → newest). Prepend as a
      // single fragment so DOM order remains chronological.
      const frag = document.createDocumentFragment();
      older.forEach((m) => {
        const node = newMessageNode();
        paintMessageNode(node, m);
        frag.appendChild(node);
      });
      thread.insertBefore(frag, thread.firstElementChild);

      oldestLoadedId = older[0]?.id ?? oldestLoadedId;

      // Restore visual position — the added content pushed everything
      // down by (newHeight - prevHeight); scrollTop needs the same shift.
      const newHeight = thread.scrollHeight;
      thread.scrollTop = prevScroll + (newHeight - prevHeight);

      setLoader(hasMore ? "" : "end");
    } catch (_) {
      // Silent — the loader hides itself in `finally`.
    } finally {
      loadingOlder = false;
      if (hasMore) setLoader("");
    }
  }

  // ---------- bootstrap ----------

  function loadBootstrap() {
    const raw = document.getElementById("byte-bootstrap")?.textContent;
    if (!raw) return [];
    try { return (JSON.parse(raw).messages || []); }
    catch { return []; }
  }

  // Initial paint: cached + bootstrap messages, then any still-queued
  // outbound entries. Pin to the bottom on first paint (this is a chat).
  messages.forEach(upsertMessage);
  allQueued().forEach(upsertQueuedMessage);
  requestAnimationFrame(() => scrollToBottom("auto"));

  // ---------- send ----------

  async function handleSend(rawBody) {
    const body = rawBody.trim();
    if (!body) return;

    input.value = "";
    autosize();

    const local_id = (typeof crypto !== "undefined" && crypto.randomUUID)
      ? crypto.randomUUID()
      : `l-${Date.now()}-${Math.random().toString(36).slice(2)}`;

    const entry = { local_id, body, metadata: { source: "web", local_id } };

    await sendMessage(entry, {
      onEnqueued: (e) => {
        upsertQueuedMessage(e);
        scrollToBottom("smooth"); // user just hit send — always scroll
      },
      onSending: (e) => markQueuedSending(e.local_id),
      onSent: (e, message) => {
        // Defensive: attach local_id even if server didn't echo it, so
        // the visual upgrade hits the queued node in place.
        message.metadata = { ...(message.metadata || {}), local_id: e.local_id };
        upsertMessage(message);
        messages = upsertPersisted(messages, message);
      },
      onTransientFail: () => {
        // Queued node stays visible; will retry on next drain trigger.
      },
      onPermanentFail: (e, reason) => markQueuedFailed(e.local_id, reason),
    });
  }

  composer.addEventListener("submit", (e) => {
    e.preventDefault();
    handleSend(input.value);
  });

  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      handleSend(input.value);
    }
  });

  function autosize() {
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, window.innerHeight * 0.3) + "px";
  }
  input.addEventListener("input", autosize);
  autosize();

  // ---------- keyboard-aware viewport pin ----------

  if (window.visualViewport) {
    const vv = window.visualViewport;
    const applyViewport = () => {
      app.style.height = vv.height + "px";
      app.style.transform = `translateY(${vv.offsetTop}px)`;
    };
    vv.addEventListener("resize", applyViewport);
    vv.addEventListener("scroll", applyViewport);
    applyViewport();
  }

  // ---------- realtime + drain triggers ----------

  function setStatus(text, cls) {
    if (!status) return;
    status.textContent = text;
    status.className = "byte-status" + (cls ? ` ${cls}` : "");
  }

  function drainHooks() {
    return {
      onSending: (e) => markQueuedSending(e.local_id),
      onSent: (e, message) => {
        message.metadata = { ...(message.metadata || {}), local_id: e.local_id };
        upsertMessage(message);
        messages = upsertPersisted(messages, message);
      },
      onPermanentFail: (e, reason) => markQueuedFailed(e.local_id, reason),
    };
  }

  function scheduleDrain() {
    if (!navigator.onLine) return;
    drainQueue(drainHooks());
  }

  Monitor.subscribe(monitorChannel, {
    connected() { setStatus("connected", "connected"); scheduleDrain(); refetchHistory(); },
    disconnected() { setStatus("disconnected", "disconnected"); },
    received(payload) {
      const data = payload?.data;
      if (!data) return;
      if (data.kind === "message" && data.message) {
        messages = upsertPersisted(messages, data.message);
        receiveMessage(data.message);
      }
    },
  });

  window.addEventListener("online",  scheduleDrain);
  window.addEventListener("focus",   scheduleDrain);

  async function refetchHistory() {
    if (!navigator.onLine || !messagesUrl) return;
    try {
      const res = await fetch(messagesUrl, {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return;
      const payload = await res.json();
      const latest = Array.isArray(payload.messages) ? payload.messages : [];
      if (typeof payload.has_more === "boolean") hasMore = payload.has_more;
      // Only anchor oldestLoadedId if we didn't already have one — a
      // scroll-back paginated fetch has already anchored an older id.
      if (!oldestLoadedId && latest[0]) oldestLoadedId = latest[0].id;

      const wasAtBottom = atBottom;
      latest.forEach((m) => {
        messages = upsertPersisted(messages, m);
        upsertMessage(m);
      });
      if (wasAtBottom) requestAnimationFrame(() => scrollToBottom("auto"));
    } catch (_) {}
  }

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState !== "visible") return;
    scheduleDrain();
    refetchHistory();
    requestShellRefresh();
  });

  // Periodic quiet drain — belt-and-suspenders for the case where the
  // page is open, online events don't fire (some mobile browsers), and
  // MonitorChannel `connected` already fired before a send failed.
  setInterval(scheduleDrain, 30_000);

  // ---------- service worker + shell sync ----------

  function setSyncBadge(text, state) {
    if (!syncBadge) return;
    syncBadge.textContent = text;
    syncBadge.dataset.state = state || "";
  }

  onShellSync((data) => {
    if (data.kind === "shell_synced") setSyncBadge("", "ok");
    else if (data.kind === "shell_sync_failed") setSyncBadge("sync failed", "failed");
  });

  await registerServiceWorker();
  await ensureByteServiceWorker(); // push registration + sub sync

  // ---------- notifications button ----------

  async function refreshNotifyBtn() {
    if (!notifyBtn) return;
    const state = await checkByteNotificationStatus();
    notifyBtn.classList.remove("subscribed", "denied", "unsupported");
    if (state === "subscribed") notifyBtn.classList.add("subscribed");
    if (state === "denied") notifyBtn.classList.add("denied");
    if (state === "unsupported") notifyBtn.classList.add("unsupported");
  }

  notifyBtn?.addEventListener("click", async () => {
    const state = await checkByteNotificationStatus();
    if (state === "subscribed") {
      await unregisterByteNotifications();
    } else if (state !== "denied" && state !== "unsupported") {
      await registerByteNotifications();
    }
    refreshNotifyBtn();
  });

  refreshNotifyBtn();

  // Initial online-drain in case we opened after being offline.
  scheduleDrain();

  // Optional: if the badge starts as 'syncing', clear after a short
  // grace period so it doesn't linger when there's nothing to sync.
  setTimeout(() => {
    if (syncBadge?.dataset.state === "syncing") setSyncBadge("", "");
  }, 4000);
});
