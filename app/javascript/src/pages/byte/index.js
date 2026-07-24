// Byte chat page. Ties together:
//   * Multi-conversation UI (drawer, mode chip, per-thread state) via
//     ConversationManager
//   * Per-conversation offline outbound queue (queue.js + api.js) so
//     sends work even with no reception and drain FIFO when it comes back
//   * localStorage-cached message history (store.js) so cold-open /
//     no-network still renders the last conversation
//   * Realtime updates via MonitorChannel — same rail used by chores,
//     agenda, timers
//   * The byte service worker (shell_sync.js) — shell caching and a
//     "syncing" badge in the header
//   * Push notifications (push.js)
//
// Never redraws the whole thread — every update is a granular upsert
// keyed by message id (or `local_id` for pre-server queued sends), per
// the no-DOM-redraw-on-sync rule.

import { Monitor } from "../dashboard/cells/monitor";
import {
  loadMessages,
  upsertPersisted,
  readLegacyCache,
  clearLegacyCache,
  clearAllPersisted,
} from "./store";
import {
  forConversation as queuedForConversation,
  readLegacyQueue,
  clearLegacyQueue,
  clearAll as clearQueue,
} from "./queue";
import { configure as configureApi, sendMessage, drainQueue } from "./api";
import {
  registerServiceWorker,
  onShellSync,
  requestShellRefresh,
  checkForServiceWorkerUpdate,
} from "./shell_sync";
import {
  ensureByteServiceWorker,
  checkByteNotificationStatus,
  registerByteNotifications,
  unregisterByteNotifications,
} from "./push";
import { ConversationManager } from "./conversations";

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
  const reloadBtn = app.querySelector("[data-byte-reload]");
  const notifyBtn = app.querySelector("[data-byte-notify]");
  const jumpBtn   = app.querySelector("[data-byte-jump]");
  const jumpCount = app.querySelector("[data-byte-jump-count]");
  const tpl       = app.querySelector("[data-byte-message-tpl]");

  const sendUrl           = app.dataset.sendUrl;
  const messagesUrl       = app.dataset.messagesUrl;
  const csrfUrl           = app.dataset.csrfUrl || "/byte/csrf";
  const conversationsUrl  = app.dataset.conversationsUrl;
  const claudeSessionsUrl = app.dataset.claudeSessionsUrl;
  const monitorChannel    = app.dataset.monitorChannel;

  configureApi({ sendUrl, csrfRefreshUrl: csrfUrl });

  // ---------- bootstrap ----------
  const bootstrap = loadBootstrap();
  const initialConversationId = bootstrap.conversation?.id
    ?? Number(app.dataset.initialConversationId || 0)
    ?? null;

  // ---------- conversation manager ----------
  //
  // ConversationManager owns the drawer + name/mode chip + create/rename/
  // archive/adopt flows. When the user switches, `handleSwitch` rebuilds
  // the visible thread from the new conversation's cache + refetches
  // history from the server. Everything else in this file works against
  // whatever `currentConversationId` currently is.
  let currentConversationId = initialConversationId;
  let messages = [];
  let atBottom      = true;
  let unreadCount   = 0;
  let hasMore       = true;
  let loadingOlder  = false;
  let oldestLoadedId = null;

  // Per-conversation unread-in-drawer counters. Only tracks conversations
  // OTHER than the currently visible one — the visible one uses
  // `unreadCount` (bottom-of-thread jump button) instead.
  const drawerUnread = new Map();

  const convoManager = new ConversationManager({
    conversationsUrl,
    claudeSessionsUrl,
    initialConversationId,
    initialConversations: bootstrap.conversations || [],
    onSwitch: (id) => handleSwitch(id),
    prefillComposer: (text, opts = {}) => {
      input.value = text;
      autosize();
      if (opts.focus !== false) {
        input.focus();
        try {
          const end = input.value.length;
          input.setSelectionRange(end, end);
        } catch (_) {}
      }
    },
    unreadFor: (id) => drawerUnread.get(id) || 0,
  });

  // ConversationManager may pick a different currentId from localStorage
  // (user's last-viewed conversation) than the server-rendered bootstrap
  // one (which is the user's most-recently-active). Sync `currentConversationId`
  // to the manager's decision, and only seed with bootstrap messages when
  // they actually belong to that conversation — otherwise we'd seed the
  // active thread with a stale sibling's messages.
  currentConversationId = convoManager.currentId ?? initialConversationId;
  const bootstrapMessages = (bootstrap.conversation && bootstrap.conversation.id === currentConversationId)
    ? (bootstrap.messages || [])
    : [];

  migrateLegacy(initialConversationId);

  hydrateForConversation(currentConversationId, bootstrapMessages);

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
    const kind = message?.metadata?.kind;
    node.className = [
      "byte-msg",
      `byte-msg-${message.direction}`,
      `byte-msg-${message.state}`,
      kind ? `byte-msg-kind-${kind}` : null,
    ].filter(Boolean).join(" ");
    const bodyEl = node.querySelector("[data-body]");

    // Kind-dispatch for body content rendering.
    //   claude          → thoughts collapsible + markdown-lite final body
    //   system          → markdown-lite (fenced code, inline code, bold, italic)
    //   shell           → server pre-rendered HTML (ANSI colours already
    //                     converted to <span> by AnsiHtml.convert)
    //   jarvis          → plain text (Jarvis responses are pre-shaped)
    //   default         → textContent (user sends, unclassified inbound)
    if (kind === "claude") {
      renderThoughts(
        node.querySelector("[data-thoughts]"),
        message.metadata && message.metadata.thoughts,
        message.state,
      );
      bodyEl.innerHTML = renderMarkdown(message.body || "");
    } else if (kind === "system") {
      bodyEl.innerHTML = renderMarkdown(message.body || "");
    } else if (kind === "shell") {
      bodyEl.innerHTML = message.body || "";
    } else if (kind === "jarvis") {
      bodyEl.textContent = message.body || "";
    } else if (kind === "action-request") {
      renderActionRequest(bodyEl, message);
    } else {
      bodyEl.textContent = message.body || "";
    }

    // Time / attachments / state apply to every kind — used to live inside
    // renderThoughts by mistake, which meant non-claude messages had blank
    // times and unpainted attachments.
    node.querySelector("[data-time]").textContent = formatTime(message.created_at);
    renderAttachments(node.querySelector("[data-attachments]"), message.attachments);
    node.querySelector("[data-state]").textContent = renderState(message);
  }

  function renderThoughts(container, thoughts, state) {
    if (!container) return;
    const list = Array.isArray(thoughts) ? thoughts : [];
    if (list.length === 0) {
      container.hidden = true;
      container.open = false;
      return;
    }
    container.hidden = false;

    const summary = container.querySelector("[data-thoughts-summary]");
    const body    = container.querySelector("[data-thoughts-body]");
    if (!summary || !body) return;

    summary.textContent =
      state === "streaming"
        ? `Thinking (${list.length} step${list.length === 1 ? "" : "s"})…`
        : `Thinking (${list.length} step${list.length === 1 ? "" : "s"})`;

    const wasAtBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 40;

    body.innerHTML = list.map((t) => {
      const type = t && t.type;
      const value = (t && t.value) || "";
      if (type === "tool_use") {
        return `<div class="byte-thought byte-thought-tool">🔧 ${escapeHtml(value)}</div>`;
      }
      if (type === "tool_result") {
        return `<div class="byte-thought byte-thought-result">${escapeHtml(value)}</div>`;
      }
      return `<div class="byte-thought byte-thought-text">${renderMarkdown(value)}</div>`;
    }).join("");

    if (state === "streaming") {
      container.open = true;
      if (wasAtBottom) body.scrollTop = body.scrollHeight;
    } else {
      container.open = false;
    }
  }

  // Action-request rendering (permission / plan / question / jarvis).
  // Reads state + button config out of message.metadata, paints the
  // header/subtitle/body/buttons, wires up tap handlers that POST the
  // user's choice to the server. Idempotent — every re-render (state
  // change, refetch, etc.) rebuilds the whole block cleanly.
  //
  // If metadata.questions is a non-empty array, we render one stacked
  // section per question (AskUserQuestion path). Otherwise we render the
  // flat button row (permission / plan / jarvis / single question).
  function renderActionRequest(container, message) {
    const meta        = message.metadata || {};
    const requestId   = meta.action_request_id;
    const actionKind  = meta.action_kind || "permission";
    const actionState = meta.action_state || "pending";
    const buttons     = Array.isArray(meta.buttons) ? meta.buttons : [];
    const questions   = Array.isArray(meta.questions) ? meta.questions : [];
    const multi       = !!meta.multi_select;
    const title       = meta.title || meta.tool_name || "Action";
    const subtitle    = meta.subtitle || "";
    const body        = message.body || "";
    const decision    = meta.action_decision || {};

    const kindClass  = `byte-action-kind-${actionKind}`;
    const stateClass = `byte-action-state-${actionState}`;
    const useQuestions = questions.length > 0;

    container.innerHTML = `
      <div class="byte-action ${kindClass} ${stateClass}" data-request-id="${escapeAttr(requestId)}">
        <div class="byte-action-head">
          <span class="byte-action-icon" aria-hidden="true">${escapeHtml(iconForKind(actionKind))}</span>
          <span class="byte-action-title">${escapeHtml(title)}</span>
        </div>
        ${subtitle && !useQuestions ? `<div class="byte-action-subtitle">${escapeHtml(subtitle)}</div>` : ""}
        ${body ? `<div class="byte-action-body">${renderMarkdown(body)}</div>` : ""}
        ${useQuestions
          ? renderQuestionSections(questions, actionState, decision)
          : `<div class="byte-action-buttons" role="group">${renderButtons(buttons, multi, actionState, decision)}</div>`}
        ${((useQuestions || multi) && actionState === "pending") ? `
          <button type="button" class="byte-action-submit" data-byte-action-submit>Submit</button>
        ` : ""}
        ${actionState === "decided" ? `
          <div class="byte-action-decided">✓ decided${decision.value ? ` — ${escapeHtml(formatDecision(decision.value))}` : ""}</div>
        ` : ""}
      </div>
    `;

    if (useQuestions) {
      wireQuestionHandlers(container, requestId, questions, actionState);
    } else {
      wireActionHandlers(container, requestId, multi, actionState);
    }
  }

  // Multi-question layout: one panel per question, each with a header,
  // the question text, and its own button group. multiSelect toggles
  // between "tap one" and "tap many + submit".
  function renderQuestionSections(questions, state, decision) {
    const disabled = state !== "pending";
    // Look up previously-decided answers per header so a re-render after
    // decision paints the chosen options.
    const decidedByHeader = new Map();
    if (Array.isArray(decision.value)) {
      decision.value.forEach((ans) => {
        if (ans && ans.header) decidedByHeader.set(ans.header, Array.isArray(ans.answers) ? ans.answers : [ans.answers]);
      });
    }

    return `<div class="byte-action-questions">
      ${questions.map((q, idx) => {
        const chosen = decidedByHeader.get(q.header) || [];
        const chosenSet = new Set(chosen.map(String));
        const opts = Array.isArray(q.options) ? q.options : [];
        return `
          <section class="byte-action-question" data-q-index="${idx}" data-multi-select="${!!q.multiSelect}">
            <div class="byte-action-question-head">
              <span class="byte-action-question-header">${escapeHtml(q.header || "Q" + (idx + 1))}</span>
              ${q.multiSelect ? `<span class="byte-action-question-hint">select any</span>` : ""}
            </div>
            <div class="byte-action-question-text">${escapeHtml(q.question || "")}</div>
            <div class="byte-action-question-options">
              ${opts.map((o) => {
                const label = o.label ?? "";
                const isChosen = chosenSet.has(String(label));
                const classes = [
                  "byte-action-btn",
                  "byte-action-btn-default",
                  isChosen ? "chosen" : "",
                  disabled ? "disabled" : "",
                ].filter(Boolean).join(" ");
                return `
                  <button type="button" class="${classes}"
                          data-byte-question-option="${escapeAttr(label)}"
                          ${disabled ? "disabled" : ""}>
                    <span class="byte-action-btn-label">${escapeHtml(label)}</span>
                    ${o.description ? `<span class="byte-action-btn-desc">${escapeHtml(o.description)}</span>` : ""}
                  </button>
                `;
              }).join("")}
            </div>
          </section>
        `;
      }).join("")}
    </div>`;
  }

  // For multi-question, track per-question selection and only enable
  // Submit when every question has ≥1 answer.
  function wireQuestionHandlers(container, requestId, questions, actionState) {
    if (actionState !== "pending" || !requestId) return;

    // selections[i] is a Set of chosen labels for question i.
    const selections = questions.map(() => new Set());

    const sections = Array.from(container.querySelectorAll(".byte-action-question"));
    const submit   = container.querySelector("[data-byte-action-submit]");

    const updateSubmit = () => {
      const allAnswered = selections.every((s) => s.size > 0);
      if (submit) submit.disabled = !allAnswered;
    };
    if (submit) submit.disabled = true; // start off, until every question answered

    sections.forEach((section, i) => {
      const isMulti = section.dataset.multiSelect === "true";
      const optionBtns = Array.from(section.querySelectorAll("[data-byte-question-option]"));

      optionBtns.forEach((btn) => {
        btn.addEventListener("click", () => {
          if (btn.disabled) return;
          const value = btn.dataset.byteQuestionOption;
          if (isMulti) {
            if (selections[i].has(value)) { selections[i].delete(value); btn.classList.remove("selected"); }
            else                          { selections[i].add(value);    btn.classList.add("selected"); }
          } else {
            selections[i].clear();
            selections[i].add(value);
            optionBtns.forEach((b) => b.classList.remove("selected"));
            btn.classList.add("selected");
          }
          updateSubmit();
        });
      });
    });

    submit?.addEventListener("click", () => {
      if (submit.disabled) return;
      submit.disabled = true;
      submit.textContent = "…";
      sections.forEach((s) => {
        Array.from(s.querySelectorAll("[data-byte-question-option]")).forEach((b) => {
          b.disabled = true;
          b.classList.add("disabled");
        });
      });
      // Wire shape matches Claude Code's AskUserQuestion output format:
      // [{ header, answers: [...] }, ...] — indexed to match questions order.
      const payload = questions.map((q, i) => ({
        header:  q.header,
        answers: Array.from(selections[i]),
      }));
      submitAction(requestId, payload, container);
    });
  }

  function iconForKind(kind) {
    switch (kind) {
      case "plan":     return "📋";
      case "question": return "?";
      case "jarvis":   return "🎩";
      default:         return "⚡";
    }
  }

  function renderButtons(buttons, multi, state, decision) {
    const disabled = state !== "pending";
    const chosenSet = new Set(Array.isArray(decision.value) ? decision.value.map(String) : (decision.value != null ? [String(decision.value)] : []));

    return buttons.map((b) => {
      const value       = b.value ?? b.label;
      const isChosen    = chosenSet.has(String(value));
      const variant     = b.variant || "default";
      const classes     = [
        "byte-action-btn",
        `byte-action-btn-${variant}`,
        isChosen ? "chosen" : "",
        disabled ? "disabled" : "",
      ].filter(Boolean).join(" ");
      const description = b.description ? `<span class="byte-action-btn-desc">${escapeHtml(b.description)}</span>` : "";
      return `
        <button type="button" class="${classes}" data-byte-action-value="${escapeAttr(String(value))}" ${disabled ? "disabled" : ""}>
          <span class="byte-action-btn-label">${escapeHtml(b.label ?? value)}</span>
          ${description}
        </button>
      `;
    }).join("");
  }

  function formatDecision(v) {
    if (Array.isArray(v)) {
      // Multi-question shape: [{header, answers}, ...]
      if (v.length && v[0] && typeof v[0] === "object" && "header" in v[0]) {
        return v.map((ans) => `${ans.header}: ${Array.isArray(ans.answers) ? ans.answers.join(", ") : ans.answers}`).join(" · ");
      }
      // Flat multi-select array
      return v.join(", ");
    }
    return String(v ?? "");
  }

  function wireActionHandlers(container, requestId, multi, actionState) {
    if (actionState !== "pending" || !requestId) return;

    const btns   = Array.from(container.querySelectorAll("[data-byte-action-value]"));
    const submit = container.querySelector("[data-byte-action-submit]");
    const selected = new Set();

    btns.forEach((btn) => {
      btn.addEventListener("click", () => {
        if (btn.disabled) return;
        const value = btn.dataset.byteActionValue;
        if (multi) {
          if (selected.has(value)) { selected.delete(value); btn.classList.remove("selected"); }
          else                     { selected.add(value);    btn.classList.add("selected"); }
        } else {
          // Optimistic: dim all, mark chosen, disable further taps until the
          // server confirms (or throws).
          btns.forEach((b) => { b.disabled = true; b.classList.add("disabled"); });
          btn.classList.add("chosen");
          submitAction(requestId, value, container);
        }
      });
    });

    submit?.addEventListener("click", () => {
      if (submit.disabled) return;
      if (selected.size === 0) return;
      submit.disabled = true;
      submit.textContent = "…";
      btns.forEach((b) => { b.disabled = true; b.classList.add("disabled"); });
      submitAction(requestId, Array.from(selected), container);
    });
  }

  async function submitAction(requestId, value, container) {
    try {
      const csrf = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
      const res  = await fetch(`/byte/actions/${encodeURIComponent(requestId)}/respond`, {
        method:      "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "Accept":       "application/json",
          "X-CSRF-Token": csrf,
        },
        body: JSON.stringify({ value: value }),
      });
      if (!res.ok) throw new Error(`http_${res.status}`);
      // The broadcast that follows will repaint the bubble with
      // action_state=decided — nothing to do here.
    } catch (e) {
      // Roll back optimistic state so the user can retry.
      Array.from(container.querySelectorAll("[data-byte-action-value]")).forEach((b) => {
        b.disabled = false;
        b.classList.remove("chosen", "disabled");
      });
      const sub = container.querySelector("[data-byte-action-submit]");
      if (sub) { sub.disabled = false; sub.textContent = "Submit"; }
      const err = document.createElement("div");
      err.className = "byte-action-error";
      err.textContent = `Couldn't send: ${e.message}. Tap again.`;
      container.appendChild(err);
    }
  }

  function escapeAttr(s) {
    return escapeHtml(String(s ?? "")).replace(/"/g, "&quot;");
  }

  function renderMarkdown(raw) {
    const stash = [];
    let t = raw;
    t = t.replace(/```([^\n`]*)\n?([\s\S]*?)```/g, (_m, lang, code) => {
      const i = stash.push({ kind: "fence", lang: (lang || "").trim(), code }) - 1;
      return `@FENCE@${i}@FENCE@`;
    });
    t = t.replace(/`([^`\n]+)`/g, (_m, code) => {
      const i = stash.push({ kind: "inline", code }) - 1;
      return `@INLINE@${i}@INLINE@`;
    });
    t = t
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
    t = t.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
    t = t.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, "$1<em>$2</em>");
    t = t.replace(/\n/g, "<br>");
    t = t.replace(/@FENCE@(\d+)@FENCE@/g, (_m, i) => {
      const b = stash[Number(i)];
      return `<pre class="byte-md-code"><code>${escapeHtml(b.code)}</code></pre>`;
    });
    t = t.replace(/@INLINE@(\d+)@INLINE@/g, (_m, i) => {
      const b = stash[Number(i)];
      return `<code class="byte-md-inline">${escapeHtml(b.code)}</code>`;
    });
    return t;
  }

  function escapeHtml(s) {
    return String(s)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;");
  }

  function upsertMessage(message) {
    let node = nodeForServerMessage(message);
    if (!node) {
      node = newMessageNode();
      thread.appendChild(node);
    }
    paintMessageNode(node, message);
    // A message that's currently STREAMING (Claude typing / shell output
    // rolling in) should always render at the bottom of the thread —
    // otherwise it's easily out-drawn by an action-request card that
    // spawned mid-turn. Move to end on every paint. Once the message
    // finalises (state != streaming), the server bumps its created_at
    // to now (touch_created_at) so it stays at the bottom naturally,
    // and we stop forcibly moving it.
    if (message.state === "streaming" && node.parentElement === thread && node !== thread.lastElementChild) {
      thread.appendChild(node);
    }
  }

  function upsertQueuedMessage(entry) {
    let node = thread.querySelector(selectorForLocal(entry.local_id));
    if (!node) {
      node = newMessageNode();
      thread.appendChild(node);
    }
    node.dataset.localId = String(entry.local_id);
    node.removeAttribute("data-message-id");
    node.className = "byte-msg byte-msg-outbound byte-msg-pending";
    node.querySelector("[data-body]").textContent = entry.body || "";
    node.querySelector("[data-time]").textContent = formatTime(new Date(entry.client_ts || entry.queued_at || Date.now()).toISOString());
    renderAttachments(node.querySelector("[data-attachments]"), []);
    node.querySelector("[data-state]").textContent = "…";
  }

  function markQueuedSending(_local_id) {}

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

  const NEAR_BOTTOM_PX = 60;
  const LOAD_TRIGGER_PX = 200;

  function measureAtBottom() {
    const gap = thread.scrollHeight - thread.scrollTop - thread.clientHeight;
    return gap < NEAR_BOTTOM_PX;
  }

  function scrollToBottom(behavior = "auto") {
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        if (behavior === "smooth") {
          thread.scrollTo({ top: thread.scrollHeight, behavior: "smooth" });
        } else {
          thread.scrollTop = thread.scrollHeight;
        }
        atBottom = true;
        clearUnread();
      });
    });
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

  function receiveMessage(message) {
    const wasAtBottom = measureAtBottom();
    const isNew = !nodeForServerMessage(message);
    upsertMessage(message);
    if (!isNew) return;
    if (wasAtBottom) {
      scrollToBottom("smooth");
    } else if (message.direction === "inbound") {
      unreadCount += 1;
      updateJumpBtn();
    }
  }

  // ---------- conversation switch / hydrate ----------

  // Bootstrap-time & post-switch fill. Clears the DOM, loads cached
  // messages for the target conversation, wires up ordering fields, and
  // kicks a background refetch to pull in anything more recent than the
  // cache. No focus/scroll gymnastics beyond pinning to bottom.
  function hydrateForConversation(convId, seedMessages) {
    Array.from(thread.querySelectorAll("[data-message-id], [data-local-id]")).forEach((n) => n.remove());
    messages = loadMessages(convId);
    (seedMessages || []).forEach((m) => { messages = upsertPersisted(convId, messages, m); });
    oldestLoadedId = messages[0]?.id ?? null;
    hasMore = true;
    unreadCount = 0;
    drawerUnread.delete(convId);
    // Repaint the drawer so its badge for this row clears immediately.
    convoManager?.render();
    updateJumpBtn();

    messages.forEach(upsertMessage);
    queuedForConversation(convId).forEach(upsertQueuedMessage);
    scrollToBottom("auto");

    refetchHistory();
  }

  function handleSwitch(nextId) {
    if (nextId === currentConversationId) return;
    currentConversationId = nextId;
    hydrateForConversation(nextId, []);
  }

  function migrateLegacy(defaultConvId) {
    if (defaultConvId == null) return;

    const legacyMsgs = readLegacyCache();
    if (legacyMsgs.length) {
      const existing = loadMessages(defaultConvId);
      legacyMsgs.forEach((m) => upsertPersisted(defaultConvId, existing, m));
      clearLegacyCache();
    }

    // Legacy queue entries lose their conversation attribution — safest
    // action is to drop them. The user was on a single conversation
    // before, so any un-drained sends are inconsequential in the
    // multi-conversation world.
    const legacyQueue = readLegacyQueue();
    if (legacyQueue.length) clearLegacyQueue();
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
    if (!oldestLoadedId) return;
    if (!navigator.onLine) return;

    loadingOlder = true;
    setLoader("loading");

    const prevHeight = thread.scrollHeight;
    const prevScroll = thread.scrollTop;
    const convIdAtStart = currentConversationId;

    try {
      const url = new URL(messagesUrl, location.href);
      url.searchParams.set("before", String(oldestLoadedId));
      url.searchParams.set("conversation_id", String(currentConversationId));
      const res = await fetch(url.toString(), {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return;
      // If the user switched conversations while we were awaiting the
      // response, discard the payload — appending it now would corrupt
      // the newly-shown thread.
      if (convIdAtStart !== currentConversationId) return;

      const payload = await res.json();
      const older = Array.isArray(payload.messages) ? payload.messages : [];
      hasMore = !!payload.has_more;

      if (older.length === 0) {
        setLoader("end");
        return;
      }

      const frag = document.createDocumentFragment();
      older.forEach((m) => {
        const node = newMessageNode();
        paintMessageNode(node, m);
        frag.appendChild(node);
      });
      thread.insertBefore(frag, thread.firstElementChild);

      oldestLoadedId = older[0]?.id ?? oldestLoadedId;

      const newHeight = thread.scrollHeight;
      thread.scrollTop = prevScroll + (newHeight - prevHeight);

      setLoader(hasMore ? "" : "end");
    } catch (_) {
    } finally {
      loadingOlder = false;
      if (hasMore) setLoader("");
    }
  }

  function loadBootstrap() {
    const raw = document.getElementById("byte-bootstrap")?.textContent;
    if (!raw) return {};
    try { return JSON.parse(raw); }
    catch { return {}; }
  }

  // ---------- send ----------

  function handleSend(rawBody) {
    const body = rawBody.trim();
    if (!body) return;

    input.value = "";
    autosize();

    if (body === "/clear" || body === "/clear-local") {
      clearLocalState();
      return;
    }

    const local_id = (typeof crypto !== "undefined" && crypto.randomUUID)
      ? crypto.randomUUID()
      : `l-${Date.now()}-${Math.random().toString(36).slice(2)}`;

    const client_ts = Date.now();
    const convId    = currentConversationId;

    const entry = {
      local_id,
      conversation_id: convId,
      body,
      client_ts,
      metadata: { source: "web", local_id, client_ts, conversation_id: convId },
    };

    sendMessage(entry, {
      onEnqueued: (e) => {
        if (e.conversation_id !== currentConversationId) return;
        upsertQueuedMessage(e);
        scrollToBottom("auto");
      },
      onSending: (e) => {
        if (e.conversation_id === currentConversationId) markQueuedSending(e.local_id);
      },
      onSent: (e, message) => {
        message.metadata = { ...(message.metadata || {}), local_id: e.local_id };
        // Even for background conversations, persist the resolved message
        // so its cache stays fresh; only paint into the DOM for the
        // currently-visible thread.
        const targetConv = e.conversation_id || currentConversationId;
        messages = targetConv === currentConversationId
          ? upsertPersisted(currentConversationId, messages, message)
          : upsertPersisted(targetConv, loadMessages(targetConv), message);
        if (targetConv === currentConversationId) upsertMessage(message);
        convoManager.bumpActivity(targetConv, message.created_at);
      },
      onTransientFail: () => {},
      onPermanentFail: (e, reason) => {
        if (e.conversation_id === currentConversationId) markQueuedFailed(e.local_id, reason);
      },
    });
  }

  function clearLocalState() {
    clearAllPersisted();
    clearQueue();
    messages = [];
    Array.from(thread.querySelectorAll("[data-message-id], [data-local-id]")).forEach((n) => n.remove());
    unreadCount = 0;
    updateJumpBtn();
    refetchHistory();
    scrollToBottom("auto");
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

  // Height source of truth: `window.innerHeight`. This is the ONE
  // measurement that iOS Safari standalone PWA reports accurately in
  // every keyboard / URL-bar state. `100dvh`, `visualViewport.height`,
  // and `position: fixed; bottom: 0` have all misbehaved on user's
  // device (composer floating mid-screen with few messages, disappearing
  // off-bottom with many messages, pushed below the keyboard on focus).
  //
  // Pump into `--byte-app-h`, then let CSS bind `.byte-app` height to it.
  // Clear any lingering `--byte-vv-height` from earlier bundles.
  document.documentElement.style.removeProperty("--byte-vv-height");

  let rafH = 0;
  const setAppHeight = () => {
    if (rafH) return;
    rafH = requestAnimationFrame(() => {
      rafH = 0;
      const wh  = window.innerHeight;
      const vvh = window.visualViewport ? Math.round(window.visualViewport.height) : null;
      // Prefer visualViewport.height when available — it always matches
      // the visible viewport (excludes keyboard). window.innerHeight can
      // report the LAYOUT viewport on some iOS PWA configurations,
      // which is bigger than what's visible when the keyboard is up.
      const h = vvh || wh;
      document.documentElement.style.setProperty("--byte-app-h", `${h}px`);
      // Debug: publish to the drawer footer so misreports are visible.
      const setV = (sel, val) => {
        const el = document.querySelector(sel);
        if (el) el.textContent = val;
      };
      setV("[data-byte-version-apph]", `${h}`);
      setV("[data-byte-version-vvh]",  vvh != null ? `${vvh}` : "n/a");
      setV("[data-byte-version-winh]", `${wh}`);
    });
  };
  setAppHeight();
  window.addEventListener("resize", setAppHeight);
  window.addEventListener("orientationchange", setAppHeight);
  window.visualViewport?.addEventListener("resize", setAppHeight);
  // Also re-measure on scroll and focus/blur — iOS fires visualViewport
  // scroll BEFORE resize in some keyboard transitions.
  window.visualViewport?.addEventListener("scroll", setAppHeight);
  window.addEventListener("focusin",  setAppHeight);
  window.addEventListener("focusout", setAppHeight);

  // Layout-viewport-scroll compensator (unchanged) — no height side-effect.
  if (window.visualViewport) {
    const vv = window.visualViewport;
    let rafId = 0;
    const applyTop = () => {
      if (rafId) return;
      rafId = requestAnimationFrame(() => {
        rafId = 0;
        if (vv.offsetTop > 0) {
          document.documentElement.style.setProperty("--byte-vv-top", `${vv.offsetTop}px`);
        } else {
          document.documentElement.style.removeProperty("--byte-vv-top");
        }
      });
    };
    vv.addEventListener("resize", applyTop, { passive: true });
    vv.addEventListener("scroll", applyTop, { passive: true });
    applyTop();
  }

  // ---------- realtime + drain triggers ----------

  function setStatus(text, cls) {
    if (!status) return;
    status.textContent = text;
    status.className = "byte-status" + (cls ? ` ${cls}` : "");
  }

  function drainHooks() {
    return {
      onSending: (e) => {
        if (e.conversation_id === currentConversationId) markQueuedSending(e.local_id);
      },
      onSent: (e, message) => {
        message.metadata = { ...(message.metadata || {}), local_id: e.local_id };
        const targetConv = e.conversation_id || currentConversationId;
        if (targetConv === currentConversationId) {
          messages = upsertPersisted(currentConversationId, messages, message);
          upsertMessage(message);
        } else {
          upsertPersisted(targetConv, loadMessages(targetConv), message);
        }
        convoManager.bumpActivity(targetConv, message.created_at);
      },
      onPermanentFail: (e, reason) => {
        if (e.conversation_id === currentConversationId) markQueuedFailed(e.local_id, reason);
      },
    };
  }

  function scheduleDrain() {
    if (!navigator.onLine) return;
    drainQueue(drainHooks());
  }

  let hasBeenConnected = false;
  let wasDisconnected  = false;

  Monitor.subscribe(monitorChannel, {
    connected() {
      setStatus("connected", "connected");
      scheduleDrain();
      refetchHistory();
      convoManager.refresh().catch(() => {});
      if (hasBeenConnected && wasDisconnected) {
        requestShellRefresh();
        checkForServiceWorkerUpdate();
      }
      hasBeenConnected = true;
      wasDisconnected  = false;
    },
    disconnected() {
      setStatus("disconnected", "disconnected");
      wasDisconnected = true;
    },
    received(payload) {
      const data = payload?.data;
      if (!data) return;
      if (data.kind === "conversation") {
        convoManager.applyBroadcast(data);
        return;
      }
      if (data.kind === "message" && data.message) {
        const msg = data.message;
        const convId = msg.conversation_id;
        // Persist to the message's conversation cache regardless of what's
        // currently visible — a background thread might get updated while
        // the user is looking at another one.
        if (convId != null) {
          const targetList = convId === currentConversationId
            ? messages
            : loadMessages(convId);
          const updated = upsertPersisted(convId, targetList, msg);
          if (convId === currentConversationId) messages = updated;
        }
        if (convId === currentConversationId) {
          receiveMessage(msg);
        } else if (msg.direction === "inbound") {
          const prev = drawerUnread.get(convId) || 0;
          drawerUnread.set(convId, prev + 1);
        }
        if (msg.created_at) convoManager.bumpActivity(convId, msg.created_at);
      }
    },
  });

  setInterval(() => {
    requestShellRefresh();
    checkForServiceWorkerUpdate();
  }, 5 * 60 * 1000);

  window.addEventListener("online",  scheduleDrain);
  window.addEventListener("focus",   scheduleDrain);

  async function refetchHistory() {
    if (!navigator.onLine || !messagesUrl) return;
    const convIdAtStart = currentConversationId;
    if (convIdAtStart == null) return;
    try {
      const url = new URL(messagesUrl, location.href);
      url.searchParams.set("conversation_id", String(convIdAtStart));
      const res = await fetch(url.toString(), {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return;
      if (convIdAtStart !== currentConversationId) return;
      const payload = await res.json();
      const latest = Array.isArray(payload.messages) ? payload.messages : [];
      if (typeof payload.has_more === "boolean") hasMore = payload.has_more;
      if (!oldestLoadedId && latest[0]) oldestLoadedId = latest[0].id;
      const wasAtBottom = atBottom;
      latest.forEach((m) => {
        messages = upsertPersisted(currentConversationId, messages, m);
        upsertMessage(m);
      });
      if (wasAtBottom) scrollToBottom("auto");
    } catch (_) {}
  }

  // Presence heartbeat. Tells Rails "user is looking at Byte right now"
  // so the webhook can skip firing a push notification. iOS would render
  // the push as an OS banner even if the SW tried to suppress it (Web
  // Push spec's userVisibleOnly forces a notification), so the ONLY
  // reliable way to avoid double-alerts is to not send the push at all.
  let presenceInterval = 0;
  const sendPresence = (state) => {
    try {
      const csrf = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
      fetch("/byte/presence", {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "Accept":       "application/json",
          "X-CSRF-Token": csrf,
        },
        body: JSON.stringify({ state: state }),
        keepalive: true,
      }).catch(() => {});
    } catch (_) {}
  };
  const startPresence = () => {
    sendPresence("visible");
    if (presenceInterval) clearInterval(presenceInterval);
    // 15s < 30s TTL server-side, so a missed heartbeat still falls off
    // within one interval and pushes resume when we're actually gone.
    presenceInterval = setInterval(() => sendPresence("visible"), 15_000);
  };
  const stopPresence = () => {
    sendPresence("hidden");
    if (presenceInterval) { clearInterval(presenceInterval); presenceInterval = 0; }
  };
  if (document.visibilityState === "visible") startPresence();
  window.addEventListener("pagehide", stopPresence);

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") {
      startPresence();
      scheduleDrain();
      refetchHistory();
      requestShellRefresh();
      checkForServiceWorkerUpdate();
    } else {
      stopPresence();
    }
  });

  setInterval(scheduleDrain, 30_000);

  // ---------- service worker + shell sync ----------

  function setSyncBadge(text, state) {
    if (!syncBadge) return;
    syncBadge.textContent = text;
    syncBadge.dataset.state = state || "";
  }

  function setUpdateAvailable(v) {
    if (!reloadBtn) return;
    reloadBtn.classList.toggle("has-update", !!v);
    if (v) {
      reloadBtn.setAttribute("title", "Update ready — tap to reload");
      reloadBtn.setAttribute("aria-label", "Update ready — tap to reload");
    } else {
      reloadBtn.setAttribute("title", "Reload");
      reloadBtn.setAttribute("aria-label", "Reload");
    }
  }

  // Actually-hard reload. The naive version (`caches.delete` + `location.reload`)
  // still lets the SW serve the OLD assets on the reloaded page — because
  //   (a) we never asked the browser to re-fetch the SW file itself, so
  //       an updated SW that's been deployed has never been installed;
  //   (b) we told any waiting SW to `skipWaiting` but didn't wait for it
  //       to activate, so the reload could beat the swap;
  //   (c) `location.reload()` on iOS PWA standalone doesn't always bypass
  //       HTTP-layer caches — a URL cache-buster param does.
  async function hardReload() {
    try {
      const reg = await navigator.serviceWorker?.getRegistration("/");

      if (reg) {
        // (a) Ask the browser to re-fetch the SW script and, if it's
        // different, install it. This is what actually pulls in a newer
        // SW file after a deploy.
        try { await reg.update(); } catch (_) {}

        // (b) Any waiting SW: activate it and wait for the swap to land.
        if (reg.waiting) {
          const waited = new Promise((resolve) => {
            const w = reg.waiting;
            if (!w) return resolve();
            const done = () => {
              if (w.state === "activated" || w.state === "redundant") resolve();
            };
            w.addEventListener("statechange", done);
            w.postMessage({ action: "skip_waiting" });
            // Belt-and-suspenders: don't hang forever if statechange never fires.
            setTimeout(resolve, 2500);
          });
          await waited;
        }
      }

      // Nuke ALL caches, not just byte-*. Some future feature might
      // introduce a new cache namespace we forget to whitelist here.
      if ("caches" in window) {
        const keys = await caches.keys();
        await Promise.all(keys.map((k) => caches.delete(k)));
      }
    } catch (_) {}

    // (c) Cache-buster forces the navigation itself past any HTTP cache.
    // Uses `replace` so the buster URL doesn't clutter back-history.
    const url = new URL(location.href);
    url.searchParams.set("_bust", Date.now().toString(36));
    location.replace(url.toString());
  }

  reloadBtn?.addEventListener("click", hardReload);

  // Populate the "sw" version footer in the drawer. Asks the active
  // service worker for its version; the SW replies via a broadcast
  // (kind: "sw_version") which lands in the onShellSync handler below.
  async function requestSwVersion() {
    try {
      const reg = await navigator.serviceWorker?.getRegistration("/");
      const sw  = reg?.active;
      const el  = document.querySelector("[data-byte-version-sw]");
      if (!sw) { if (el) el.textContent = "(none)"; return; }
      sw.postMessage({ action: "get_version" });
    } catch (_) {}
  }
  requestSwVersion();

  onShellSync((data) => {
    if (data.kind === "shell_synced") {
      setSyncBadge("", "ok");
    } else if (data.kind === "shell_sync_failed") {
      setSyncBadge("sync failed", "failed");
    } else if (data.kind === "shell_updated") {
      setUpdateAvailable(true);
    } else if (data.kind === "sw_version") {
      const el = document.querySelector("[data-byte-version-sw]");
      if (el) el.textContent = (data.cache || "?").replace(/^byte-/, "");
    }
  });

  let hadInitialController = !!navigator.serviceWorker?.controller;
  navigator.serviceWorker?.addEventListener("controllerchange", () => {
    if (!hadInitialController) {
      hadInitialController = true;
      return;
    }
    setUpdateAvailable(true);
  });

  await registerServiceWorker();
  await ensureByteServiceWorker();

  // ---------- notifications button ----------

  async function refreshNotifyBtn() {
    if (!notifyBtn) return;
    const state = await checkByteNotificationStatus();
    notifyBtn.classList.remove("subscribed", "denied", "unsupported");
    if (state === "subscribed") notifyBtn.classList.add("subscribed");
    if (state === "denied") notifyBtn.classList.add("denied");
    if (state === "unsupported") notifyBtn.classList.add("unsupported");
    const title = {
      subscribed:   "Notifications on — tap to disable",
      unsubscribed: "Notifications off — tap to enable",
      denied:       "Blocked by browser — enable in site settings",
      unsupported:  "Notifications unavailable in this browser",
    }[state] || "Toggle notifications";
    notifyBtn.setAttribute("title", title);
    notifyBtn.setAttribute("aria-label", title);
  }

  function surfaceLocal(body, kind = "system") {
    const stub = {
      id:              `local-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      conversation_id: currentConversationId,
      direction:       "inbound",
      state:           "delivered",
      body:            body,
      created_at:      new Date().toISOString(),
      metadata:        { kind: kind, local: true },
      attachments:     [],
    };
    upsertMessage(stub);
    if (atBottom) scrollToBottom("smooth");
  }

  notifyBtn?.addEventListener("click", async () => {
    const state = await checkByteNotificationStatus();
    if (state === "unsupported") {
      surfaceLocal("**Notifications unavailable** — this browser doesn't support Web Push.");
      return;
    }
    if (state === "denied") {
      surfaceLocal(
        "**Notifications blocked.** Enable them in your browser settings for this site, then tap the bell again.",
      );
      return;
    }
    if (state === "subscribed") {
      await unregisterByteNotifications();
      surfaceLocal("Notifications **disabled**.");
    } else {
      const result = await registerByteNotifications();
      if (result && result.success) {
        surfaceLocal("Notifications **enabled**. Try `byte \"test\"` from your Mac to verify.");
      } else {
        const reason = (result && result.error) || "unknown error";
        surfaceLocal(`**Couldn't enable notifications:** \`${reason}\``);
      }
    }
    refreshNotifyBtn();
  });

  refreshNotifyBtn();

  scheduleDrain();

  setTimeout(() => {
    if (syncBadge?.dataset.state === "syncing") setSyncBadge("", "");
  }, 4000);
});
