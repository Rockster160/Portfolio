// Byte chat surface. Purpose: single-thread chat UI for talking to
// the local Mac-side automation server. Sends via HTTP, receives via
// MonitorChannel (same broadcast rail used by chores/timers/agenda).
//
// The DOM tree, bootstrap payload, and template all live in
// `app/views/byte/show.html.erb` — this file is a strict view
// controller. It never redraws the whole thread; it upserts individual
// message nodes on every event to avoid flicker/focus loss (see
// feedback_no_dom_redraw_on_sync).

import { Monitor } from "./dashboard/cells/monitor";
import {
  ensureByteServiceWorker,
  checkByteNotificationStatus,
  registerByteNotifications,
  unregisterByteNotifications,
} from "./byte_push";

document.addEventListener("DOMContentLoaded", async () => {
  const app = document.querySelector(".byte-app");
  if (!app) return;

  const thread   = app.querySelector("[data-byte-thread]");
  const composer = app.querySelector("[data-byte-composer]");
  const input    = app.querySelector("[data-byte-input]");
  const sendBtn  = app.querySelector("[data-byte-send]");
  const status   = app.querySelector("[data-byte-status]");
  const notifyBtn = app.querySelector("[data-byte-notify]");
  const tpl      = app.querySelector("[data-byte-message-tpl]");

  const sendUrl     = app.dataset.sendUrl;
  const messagesUrl = app.dataset.messagesUrl;
  const monitorChannel = app.dataset.monitorChannel;

  const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;

  // ---------- rendering ----------

  const timeFmt = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit" });

  function formatTime(iso) {
    if (!iso) return "";
    try { return timeFmt.format(new Date(iso)); } catch { return ""; }
  }

  function nodeForId(id) {
    return thread.querySelector(`[data-message-id="${CSS.escape(String(id))}"]`);
  }

  function upsertMessage(message) {
    let node = nodeForId(message.id);
    if (!node) {
      node = tpl.content.firstElementChild.cloneNode(true);
      node.dataset.messageId = String(message.id);
      thread.appendChild(node);
    }
    node.className = [
      "byte-msg",
      `byte-msg-${message.direction}`,
      `byte-msg-${message.state}`,
    ].join(" ");
    node.querySelector("[data-body]").textContent = message.body || "";
    node.querySelector("[data-time]").textContent = formatTime(message.created_at);

    renderAttachments(node.querySelector("[data-attachments]"), message.attachments);

    const stateEl = node.querySelector("[data-state]");
    stateEl.textContent = renderState(message);
  }

  function renderAttachments(container, attachments) {
    if (!container) return;
    const list = Array.isArray(attachments) ? attachments : [];
    // Bail out if the DOM already matches the incoming attachments — otherwise
    // every streaming update would flicker/reload every <img> in the message.
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
      img.src = a.url;
      img.alt = a.filename || "";
      img.loading = "lazy";
      wrap.appendChild(img);
    } else if (type === "audio") {
      const audio = document.createElement("audio");
      audio.src = a.url;
      audio.controls = true;
      wrap.appendChild(audio);
    } else if (type === "video") {
      const video = document.createElement("video");
      video.src = a.url;
      video.controls = true;
      video.playsInline = true;
      wrap.appendChild(video);
    } else {
      const link = document.createElement("a");
      link.href = a.url;
      link.textContent = a.filename || "file";
      link.download = a.filename || "";
      link.rel = "noopener";
      link.target = "_blank";
      wrap.appendChild(link);
    }
    return wrap;
  }

  function renderState(message) {
    // Streaming shows via the cursor in SCSS; no textual label needed.
    if (message.state === "streaming") return "";
    if (message.direction !== "outbound") return "";
    if (message.state === "pending") return "…";
    if (message.state === "failed") return "failed";
    return "";
  }

  function stickToBottomIfClose(behavior = "auto") {
    // Only auto-scroll if the user is already near the bottom — otherwise
    // we'd yank them out of scrollback while they're reading.
    const gap = thread.scrollHeight - thread.scrollTop - thread.clientHeight;
    if (gap < 120) thread.scrollTo({ top: thread.scrollHeight, behavior });
  }

  // ---------- bootstrap ----------

  function loadBootstrap() {
    const raw = document.getElementById("byte-bootstrap")?.textContent;
    if (!raw) return [];
    try { return (JSON.parse(raw).messages || []); } catch { return []; }
  }

  loadBootstrap().forEach(upsertMessage);
  stickToBottomIfClose("auto");

  // ---------- send ----------

  async function sendMessage(body) {
    const trimmed = body.trim();
    if (!trimmed) return;

    input.value = "";
    autosize();

    try {
      const resp = await fetch(sendUrl, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": csrfToken,
        },
        credentials: "same-origin",
        body: JSON.stringify({ body: trimmed, source: "web" }),
      });
      if (resp.ok) {
        const message = await resp.json();
        upsertMessage(message);
        stickToBottomIfClose("smooth");
      } else {
        console.warn("[byte] send failed", resp.status);
      }
    } catch (e) {
      console.warn("[byte] send crashed", e);
    }
  }

  composer.addEventListener("submit", (e) => {
    e.preventDefault();
    sendMessage(input.value);
  });

  // Enter to send, Shift+Enter for newline. Standard chat ergonomics.
  input.addEventListener("keydown", (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      sendMessage(input.value);
    }
  });

  function autosize() {
    input.style.height = "auto";
    input.style.height = Math.min(input.scrollHeight, window.innerHeight * 0.3) + "px";
  }
  input.addEventListener("input", autosize);
  autosize();

  // iOS Safari < 17.4 doesn't honour `interactive-widget=resizes-content`,
  // so 100dvh stays constant when the keyboard opens and the app slides
  // behind it. visualViewport reports the real visible area — pin the app
  // height to it and shove it up by the visual offset when needed.
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

  // ---------- realtime (MonitorChannel) ----------

  function setStatus(text, cls) {
    if (!status) return;
    status.textContent = text;
    status.className = "byte-status" + (cls ? ` ${cls}` : "");
  }

  Monitor.subscribe(monitorChannel, {
    connected() { setStatus("connected", "connected"); },
    disconnected() { setStatus("disconnected", "disconnected"); },
    received(payload) {
      const data = payload?.data;
      if (!data) return;
      if (data.kind === "message" && data.message) {
        upsertMessage(data.message);
        stickToBottomIfClose("smooth");
      }
    },
  });

  // ---------- notifications ----------

  async function refreshNotifyBtn() {
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

  await ensureByteServiceWorker();
  refreshNotifyBtn();

  // Re-fetch history if we've been backgrounded a while — the Monitor
  // may have missed a broadcast during a socket flap.
  document.addEventListener("visibilitychange", async () => {
    if (document.visibilityState !== "visible") return;
    try {
      const resp = await fetch(messagesUrl, { credentials: "same-origin" });
      if (!resp.ok) return;
      const { messages } = await resp.json();
      (messages || []).forEach(upsertMessage);
      stickToBottomIfClose("auto");
    } catch (_) {}
  });
});
