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
  removePersisted,
  readLegacyCache,
  clearLegacyCache,
  clearAllPersisted,
} from "./store";
import {
  forConversation as queuedForConversation,
  readLegacyQueue,
  clearLegacyQueue,
  clearAll as clearQueue,
  removeByLocalId as removeQueued,
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
  byteSubscriptionEndpoint,
} from "./push";
import { ConversationManager } from "./conversations";
import { initComposerAttachments } from "./attachments";
import { setupSlashAutocomplete } from "./slash_commands";
import { renderMultiSelect } from "./message_actions/multi_select";
import { renderForm } from "./message_actions/form";
import { initMessageContextMenu } from "./message_actions/context_menu";
import { renderMarkdown, escapeHtml, escapeAttr } from "./markdown";
import { initBuddyHero } from "./buddy/hero";
import { initBuddyTimers } from "./buddy/timers";
import { initBuddyRoutines } from "./buddy/routines";
import { initBuddyReminders } from "./buddy/reminders";
import { initBuddyKiosk } from "./buddy/kiosk";
import { toggleBuddyMuted, isBuddyMuted } from "./buddy/alarm";
import {
  UnreadTracker,
  paintDrawerBadge,
  paintAppBadge,
  initUnreadNotices,
  previewOf,
} from "./unread";

document.addEventListener("DOMContentLoaded", async () => {
  const app = document.querySelector(".byte-app");
  if (!app) return;

  // Per-node timers that expire the "byte-msg-live" class after a
  // period of no updates. Declared at the very top of the handler
  // scope so hydrate-time calls into paintMessageNode → markLive can't
  // hit a TDZ error on `liveExpireTimers`. See index.js's earlier
  // reload-clears-cursor work for the semantics.
  const liveExpireTimers = new WeakMap();
  // Fallback window before a live bubble's cursor is dropped when NO further
  // updates arrive. A tool call or a stretch of thinking legitimately runs
  // longer than 15s with no intermediate stream, and the old 15s window made
  // the cursor vanish mid-turn so the reply looked stuck/abandoned. 45s keeps
  // the cursor alive across a normal tool call; a genuinely dead stream still
  // clears within one window. (Buddy also emits a "Hang on, I'll look into
  // it..." interim line before slow tool calls, which resets this timer.)
  const LIVE_EXPIRE_MS = 45000;
  function markLive(node) {
    node.classList.add("byte-msg-live");
    const prev = liveExpireTimers.get(node);
    if (prev) clearTimeout(prev);
    liveExpireTimers.set(
      node,
      setTimeout(() => {
        node.classList.remove("byte-msg-live");
        liveExpireTimers.delete(node);
      }, LIVE_EXPIRE_MS),
    );
  }
  function unmarkLive(node) {
    node.classList.remove("byte-msg-live");
    const t = liveExpireTimers.get(node);
    if (t) {
      clearTimeout(t);
      liveExpireTimers.delete(node);
    }
  }

  // ---------- DOM refs ----------
  const thread = app.querySelector("[data-byte-thread]");
  const loader = app.querySelector("[data-byte-loader]");
  const composer = app.querySelector("[data-byte-composer]");
  const input = app.querySelector("[data-byte-input]");
  const originalPlaceholder = input?.getAttribute("placeholder") ?? "";
  // True while the composer has focus (keyboard up / user typing). In that
  // state we pin to the bottom UNCONDITIONALLY: the user is on the newest
  // message and the keyboard must never cover it. This bypasses the atBottom
  // heuristic, which flips false transiently mid-keyboard-animation and was
  // stranding the thread scrolled up under the keyboard.
  const composerFocused = () => document.activeElement === input;
  const status = app.querySelector("[data-byte-status]");
  const syncBadge = app.querySelector("[data-byte-sync]");
  const reloadBtn = app.querySelector("[data-byte-reload]");
  const notifyBtn = app.querySelector("[data-byte-notify]");
  const jumpBtn = app.querySelector("[data-byte-jump]");
  const jumpCount = app.querySelector("[data-byte-jump-count]");
  const heroEl = app.querySelector("[data-buddy-hero]");
  const sleepChip = app.querySelector("[data-byte-sleep-chip]");
  const sleepText = app.querySelector("[data-byte-sleep-text]");
  // Assigned right after handleSend is defined (below) — declared here so
  // handleSwitch (which can fire before the hero is mounted on the first
  // render) doesn't hit a TDZ error.
  let buddyHero = null;
  // Same reason: hydrateForConversation runs during init and feeds this, well
  // before the mount point below exists. Null on every page but the kiosk.
  let buddyKiosk = null;
  const tpl = app.querySelector("[data-byte-message-tpl]");

  const sendUrl = app.dataset.sendUrl;
  const messagesUrl = app.dataset.messagesUrl;
  const csrfUrl = app.dataset.csrfUrl || "/byte/csrf";
  const conversationsUrl = app.dataset.conversationsUrl;
  const claudeSessionsUrl = app.dataset.claudeSessionsUrl;
  const monitorChannel = app.dataset.monitorChannel;

  // Whatever THIS thread's companion is called. Server-rendered from the active
  // conversation's theme and repointed by applyBuddyTheme on every switch, so
  // any copy that names the pet ("… is asleep") reads it from here rather than
  // hardcoding one companion's name.
  //
  // The fallback walks to the account's own default pet rather than a literal.
  // Naming the wrong companion is the one thing this must never do, and a
  // hardcoded "Byte" in a Suki thread is exactly that.
  const buddyName = () =>
    app.dataset.buddyName ||
    buddyThemes[app.dataset.defaultBuddyTheme]?.name ||
    "Your buddy";

  // Every pet's name, colour, icons and faces, rendered once from
  // Buddy::Themes (see ByteHelper#buddy_themes_json). Keyed by theme, and
  // includes pets with no open thread — the drawer rows and face warming both
  // need those.
  const buddyThemes = (() => {
    try {
      return JSON.parse(app.dataset.buddyThemes || "{}");
    } catch (e) {
      return {};
    }
  })();

  // This user's own pet, worn by any thread that isn't a Buddy one.
  const defaultBuddyTheme = app.dataset.defaultBuddyTheme || "byte";

  // The face a pet settles back to. Declared up here because applyBuddyTheme
  // resets to it on every conversation switch, well before the sleep/wake block
  // that also uses it.
  const DEFAULT_WAKE_EXPRESSION =
    document.querySelector("[data-buddy-hero]")?.dataset.buddyAwakeExpression ||
    "happy";

  configureApi({ sendUrl, csrfRefreshUrl: csrfUrl });

  // ---------- bootstrap ----------
  const bootstrap = loadBootstrap();
  const initialConversationId =
    bootstrap.conversation?.id ??
    Number(app.dataset.initialConversationId || 0) ??
    null;

  // The thread the URL asked for, if any. #show honours it too, so on a normal
  // reload this agrees with what the server rendered — it's read here so an
  // explicit link still wins over this browser's last-viewed thread.
  const urlConversationId =
    Number(new URLSearchParams(location.search).get("conversation_id")) || null;

  // The wall tablet. It has no drawer, so it is only ever on one thread — and
  // it takes the server's, not this browser's last-viewed one, which on a
  // device that also opens the chat would be whatever was read there last.
  const isKiosk = app.dataset.kiosk === "true";

  // ---------- conversation manager ----------
  //
  // ConversationManager owns the drawer + name/mode chip + create/rename/
  // archive/adopt flows. When the user switches, `handleSwitch` rebuilds
  // the visible thread from the new conversation's cache + refetches
  // history from the server. Everything else in this file works against
  // whatever `currentConversationId` currently is.
  let currentConversationId = initialConversationId;
  let messages = [];
  let atBottom = true;
  let unreadCount = 0;
  let hasMore = true;
  let loadingOlder = false;
  // Declared up here (not next to scrollToBottom) because hydrateForConversation
  // runs during init BEFORE the scroll section and calls scrollToBottom, which
  // reads stickRaf — a `let` down there would be in its TDZ and throw.
  let stickRaf = 0;
  // Coalesces the growth-observer's re-pins into one write per frame (see the
  // MutationObserver in the scroll section). Declared here for the same TDZ
  // reason as stickRaf.
  let pinRaf = 0;
  // A conversation load (first paint or a drawer switch) must land pinned to
  // the newest message. The `atBottom` heuristic can't be trusted mid-load —
  // clearing the previous thread emits a scroll event that reads "not at
  // bottom" before the new messages lay out — so a switched-into thread used
  // to strand at the top (and then auto-load older, keeping it there).
  // `stickThroughLoad` keeps the pin asserted across the whole load (initial
  // render, network refetch, late layout) and is released the instant the user
  // scrolls or the load settles. Same TDZ reason for living up here: hydrate
  // reads it during init.
  let stickThroughLoad = false;
  let stickThroughLoadTimer = 0;
  // Sleep/queue state — declared early for the same TDZ reason (hydrate and
  // conversation switches can read them before the sleep section runs).
  let channelConnected = false;
  let sleepUntil = bootstrap.buddy_sleep?.sleep_until || null; // ISO string or null
  let sleepWake = bootstrap.buddy_sleep?.wake_string || null; // "8:00 AM" or null
  let oldestLoadedId = null;

  // Per-conversation unread-in-drawer counters. Only tracks conversations
  // OTHER than the currently visible one — the visible one uses
  // `unreadCount` (bottom-of-thread jump button) instead.
  //
  // Counts settled message IDS, not broadcasts: see unread.js for why a plain
  // tally ran away during a long Claude turn.
  const drawerBadge = document.querySelector("[data-byte-drawer-badge]");
  const drawerUnread = new UnreadTracker({
    onChange: () => {
      const total = drawerUnread.total();
      paintDrawerBadge(drawerBadge, total);
      paintAppBadge(total);
    },
  });
  // The kiosk is a pinned single-conversation display with no thread and no
  // header, and it can't be switched away from — a card about another
  // conversation there is something nobody can act on. `initUnreadNotices`
  // with no root returns a no-op notifier, which is exactly right.
  const unreadNotices = initUnreadNotices({
    root: isKiosk ? null : document.querySelector("[data-byte-notices]"),
    onOpen: (convId) => convoManager?.switchTo(convId),
  });

  const convoManager = new ConversationManager({
    conversationsUrl,
    claudeSessionsUrl,
    initialConversationId,
    pinnedConversationId:
      urlConversationId ?? (isKiosk ? initialConversationId : null),
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
    // Drawer actions that auto-send (e.g. adopt) route through the same
    // sendMessage pipeline the composer uses, but target an explicit
    // conversation id so the command lands in the right thread even if
    // the user is currently viewing a different one.
    sendCommand: (convId, body) => sendMessageTo(convId, body),
    unreadFor: (id) => drawerUnread.countFor(id),
    // Every refetch of the list carries fresh server-side counts. Re-seeding
    // from them is what catches a session up after it's been backgrounded.
    onConversations: (list) =>
      drawerUnread.seedAll(list, { except: currentConversationId }),
  });

  // ConversationManager may pick a different currentId from localStorage
  // (user's last-viewed conversation) than the server-rendered bootstrap
  // one (which is the user's most-recently-active). Sync `currentConversationId`
  // to the manager's decision, and only seed with bootstrap messages when
  // they actually belong to that conversation — otherwise we'd seed the
  // active thread with a stale sibling's messages.
  currentConversationId = convoManager.currentId ?? initialConversationId;
  const bootstrapMessages =
    bootstrap.conversation &&
    bootstrap.conversation.id === currentConversationId
      ? bootstrap.messages || []
      : [];

  migrateLegacy(initialConversationId);

  // Seed the badges from what the server counted, BEFORE hydrating — hydrate
  // clears the thread being opened, and seeding after it would put a count back
  // on the one conversation that's being read right now.
  //
  // This is the half that was missing: unread lived only in the page, so a
  // reload started at zero and anything that arrived while the app was closed
  // was never counted at all.
  drawerUnread.seedAll(convoManager.conversations, { except: currentConversationId });

  hydrateForConversation(currentConversationId, bootstrapMessages);

  // ---------- rendering primitives ----------

  const timeFmt = new Intl.DateTimeFormat(undefined, {
    hour: "numeric",
    minute: "2-digit",
  });

  function formatTime(iso) {
    if (!iso) return "";
    try {
      return timeFmt.format(new Date(iso));
    } catch {
      return "";
    }
  }

  function cssEscape(s) {
    return typeof CSS !== "undefined" && CSS.escape
      ? CSS.escape(s)
      : s.replace(/"/g, '\\"');
  }

  function selectorForId(id) {
    return `[data-message-id="${cssEscape(String(id))}"]`;
  }
  function selectorForLocal(local) {
    return `[data-local-id="${cssEscape(String(local))}"]`;
  }

  function nodeForServerMessage(message) {
    const localId = message?.metadata?.local_id;
    if (localId) {
      const local = thread.querySelector(selectorForLocal(localId));
      if (local) return local;
    }
    return thread.querySelector(selectorForId(message.id));
  }

  // What comes back from a send is normally the server's ECHO of the message
  // just sent, so it inherits the entry's local_id and takes over the
  // optimistic bubble.
  //
  // A Rails slash command is the exception. It deliberately stores no outbound
  // record, and what it returns is a different message entirely: an inbound
  // system acknowledgement. Stamping the local_id onto that told the client
  // the ack WAS the echo, so it repainted the optimistic "/reset" bubble into
  // an ack — and the broadcast of the same ack, which carries no local_id,
  // mounted a second one beside it. Prod 2513: two identical bubbles, one row.
  function adoptSendResponse(entry, message) {
    if (message?.direction === "outbound") {
      message.metadata = {
        ...(message.metadata || {}),
        local_id: entry.local_id,
      };
      return message;
    }
    // Not an echo. The command left no bubble of its own on purpose, so drop
    // the optimistic one and let the reply mount on its own id.
    thread.querySelector(selectorForLocal(entry.local_id))?.remove();
    return message;
  }

  function newMessageNode() {
    return tpl.content.firstElementChild.cloneNode(true);
  }

  function paintMessageNode(node, message, opts = {}) {
    const live = opts.live === true;
    node.dataset.messageId = String(message.id);
    // Raw body stashed for the long-press "Copy full message" action — the
    // rendered bubble is markdown-HTML, so this preserves the exact source.
    node.dataset.fullBody = message.body || "";
    if (message?.metadata?.local_id)
      node.dataset.localId = String(message.metadata.local_id);
    const kind = message?.metadata?.kind;
    // Preserve the byte-msg-live class across className rewrite — CSS
    // gates the cursor / pulse animations on it, and losing it here
    // would visually stop the animation for one paint cycle every WS
    // update on a live-streaming bubble.
    const wasLive = node.classList.contains("byte-msg-live");
    node.className = [
      "byte-msg",
      `byte-msg-${message.direction}`,
      `byte-msg-${message.state}`,
      kind ? `byte-msg-kind-${kind}` : null,
    ]
      .filter(Boolean)
      .join(" ");
    if (wasLive) node.classList.add("byte-msg-live");
    // Cancel ✕ only on messages still held server-side (Buddy asleep). Once
    // it dispatches (sent/delivered) it's out of the user's hands.
    const cancelBtn = node.querySelector("[data-msg-cancel]");
    if (cancelBtn)
      cancelBtn.hidden = !(
        message.direction === "outbound" && message.state === "queued"
      );
    const bodyEl = node.querySelector("[data-body]");

    // Cross-user relay attribution: a bridged message carries `relay_peer`
    // (the OTHER household's Buddy — name/theme/icon). Incoming relays show
    // that avatar+name alone. The sender-side copy also carries `relay_from`
    // (your own Buddy) and renders "yours → theirs", so it doesn't read as
    // something the partner's Buddy said. The bubble is tinted for whichever
    // Buddy is speaking rather than the default inbound tint.
    // Activity-chip footnote: which tool ran and the args it ran with. Only
    // level-1 actions carry one - they leave no checklist row, so this is the
    // only record of what happened.
    const detailEl = node.querySelector("[data-activity-detail]");
    if (detailEl) {
      const detail = message?.metadata?.detail;
      detailEl.hidden = !detail;
      detailEl.textContent = detail || "";
    }

    const peer = message?.metadata?.relay_peer;
    const relayFrom = message?.metadata?.relay_from;
    const peerEl = node.querySelector("[data-peer]");
    if (peerEl) {
      const fromIconEl = peerEl.querySelector("[data-peer-from-icon]");
      const arrowEl = peerEl.querySelector("[data-peer-arrow]");
      const outgoing = Boolean(peer && relayFrom?.icon);
      if (peer && (peer.name || peer.icon)) {
        peerEl.hidden = false;
        const iconEl = peerEl.querySelector("[data-peer-icon]");
        if (iconEl) iconEl.src = peer.icon || "";
        const nameEl = peerEl.querySelector("[data-peer-name]");
        if (nameEl) nameEl.textContent = peer.name || "";
        if (fromIconEl) {
          fromIconEl.hidden = !outgoing;
          if (outgoing) fromIconEl.src = relayFrom.icon;
        }
        if (arrowEl) arrowEl.hidden = !outgoing;
        node.dataset.peerTheme =
          (outgoing ? relayFrom.theme : peer.theme) || "";
      } else {
        peerEl.hidden = true;
        if (fromIconEl) fromIconEl.hidden = true;
        if (arrowEl) arrowEl.hidden = true;
        node.removeAttribute("data-peer-theme");
      }
    }

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
    } else if (kind === "action_chip") {
      // Small centered status pill (e.g. "Check-in: Good", "What now?")
      // marking a quick-action tap. Not a real message from either side;
      // CSS gives it a distinct centered chip look.
      bodyEl.textContent = message.body || "";
    } else if (kind === "buddy_activity") {
      // A trusted tool ran WITHOUT a confirmation checkbox (e.g. a reminder
      // was scheduled). Reads as an activity receipt - a centered pill,
      // clearly not a message - via CSS. Markdown because receipts bold the
      // thing they acted on, and rendering that literally showed the asterisks.
      bodyEl.innerHTML = renderMarkdown(message.body || "");
    } else if (
      kind === "buddy_reply" ||
      kind === "buddy" ||
      kind === "buddy_receipt" ||
      kind === "buddy_relay"
    ) {
      // Every Buddy inbound message renders as markdown so **bold**,
      // bulleted lists, and inline code all look right. `buddy_reply`
      // is set by ProposalBuilder on replies that carry a checklist;
      // `buddy` is Mac's default kind for a plain reply; `buddy_receipt`
      // is the post-execution "Done ✓ ..." summary. All same treatment.
      //
      // While the turn is still running the body is only a placeholder, so
      // the bubble shows what Buddy is DOING instead — see renderSteps. The
      // class is what swaps the typing cursor for the step pulse; className
      // was rebuilt above, so it lasts exactly one paint, which is right.
      if (message.state === "streaming") {
        bodyEl.innerHTML = renderSteps(message?.metadata?.steps);
        node.classList.add("byte-msg-stepping");
      } else {
        bodyEl.innerHTML = renderMarkdown(message.body || "");
      }
    } else if (kind === "watch") {
      // Watch bubbles carry a `wait_label` while running, then a plain
      // markdown completion body once done. Render markdown either way.
      bodyEl.innerHTML = renderMarkdown(message.body || "");
    } else {
      bodyEl.textContent = message.body || "";
    }

    // Watch messages that are still running get a subtle animated dot
    // next to their label so the user can see the task is live, not
    // stuck. Once state flips to delivered/failed, the class comes off.
    const waitLabel = message?.metadata?.wait_label;
    if (kind === "watch" && message.state === "streaming" && waitLabel) {
      node.classList.add("byte-msg-watching");
    } else {
      node.classList.remove("byte-msg-watching");
    }

    // If this message carries a Buddy proposal checklist, mount (or
    // re-mount) the multi-select renderer below the body. Idempotent —
    // each paint clears the container and re-renders from message.metadata.
    if (
      message?.metadata?.tool_name === "buddy_proposals" ||
      message?.metadata?.tool_name === "buddy_relay_answer" ||
      message?.metadata?.tool_name === "buddy_reminders_manage"
    ) {
      let checklistEl = node.querySelector("[data-buddy-checklist]");
      if (!checklistEl) {
        checklistEl = document.createElement("div");
        checklistEl.setAttribute("data-buddy-checklist", "");
        bodyEl.parentNode.insertBefore(checklistEl, bodyEl.nextSibling);
      }
      renderMultiSelect(checklistEl, message);
    }

    // An editable form (Buddy::FormAction). Its own container, since a message
    // carries one action and this is never mixed with a checklist.
    if (message?.metadata?.tool_name === "buddy_form") {
      let formEl = node.querySelector("[data-buddy-form]");
      if (!formEl) {
        formEl = document.createElement("div");
        formEl.setAttribute("data-buddy-form", "");
        bodyEl.parentNode.insertBefore(formEl, bodyEl.nextSibling);
      }
      // Widens the bubble (see .byte-msg-has-form). A form is a data-entry
      // surface, not a sentence — several fields, long option labels, and a
      // native date picker that won't render below a certain width. Added
      // after the className rebuild above, which would wipe it.
      node.classList.add("byte-msg-has-form");
      renderForm(formEl, message);
    }

    // Time / attachments / state apply to every kind — used to live inside
    // renderThoughts by mistake, which meant non-claude messages had blank
    // times and unpainted attachments.
    node.querySelector("[data-time]").textContent = formatTime(
      message.created_at,
    );
    // Raw ISO stamp so reorderActiveTail can sort settled messages by
    // effective "sent" time. Claude responses have their created_at
    // bumped on finalisation (touch_created_at); action-requests keep
    // their original — so a decided action ends up ABOVE the response
    // even when the response finished streaming first.
    if (message.created_at) node.dataset.createdAt = message.created_at;
    renderAttachments(
      node.querySelector("[data-attachments]"),
      message.attachments,
    );
    node.querySelector("[data-state]").textContent = renderState(message);

    // Tag the node with its "active" role so the tail-reorder pass can
    // float in-flight items to the bottom. A message is active while it's
    // still being produced or is waiting on the user:
    //   * streaming = a response mid-write (Claude typing, shell rolling)
    //   * pending   = an action-request awaiting the user's tap
    // Once it settles (response delivered, action decided), the tag is
    // dropped and the node takes its natural created_at position — which,
    // for finalised Claude responses, is bumped via touch_created_at so
    // the answered action-request ends up sitting ABOVE the response
    // (as if it had "sent" earlier, which is when it actually happened).
    const actionState =
      kind === "action-request"
        ? message?.metadata?.action_state || "pending"
        : null;
    if (message.state === "streaming" && kind !== "action-request") {
      node.dataset.activeKind = "streaming";
    } else if (kind === "action-request" && actionState === "pending") {
      node.dataset.activeKind = "pending";
    } else {
      delete node.dataset.activeKind;
    }

    // Liveness gate for the cursor / pulse animations. Only paints that
    // came from an actual fresh WS event mark the node live (with a
    // 15s auto-expiry). Hydrate/history paints intentionally UNmark it
    // so a stale state:"streaming" from a crashed process doesn't spin
    // forever after a reload.
    if (message.state === "streaming" && live) {
      markLive(node);
    } else if (message.state !== "streaming") {
      unmarkLive(node);
    }
    // Intentional gap: if state === "streaming" and !live, we do NOT
    // call unmarkLive — we just don't refresh the timer. If the node
    // WAS live from a prior WS update, it stays live until the timer
    // expires naturally.
  }

  // What a Buddy turn is doing, while it's still doing it. The server pushes a
  // line per tool call on the broadcast only (never persisted), so this grows
  // as the turn runs and is gone the moment the real reply replaces it.
  //
  // Every line stays visible rather than swapping in place: a turn that checks
  // the calendar, then the printer, then gives up is a different wait from one
  // that answers straight away, and only the accumulated list tells them apart.
  // The last line is the live one and carries the pulse.
  // `byte-think-*`, not `byte-step-*`: the routines manager already owns
  // `.byte-step` for its draggable rows, and its flex/padding rules were
  // landing on these.
  function renderSteps(steps) {
    const list = Array.isArray(steps) ? steps.filter(Boolean) : [];
    if (list.length === 0)
      return `<span class="byte-think-step byte-think-now">Thinking</span>`;

    return list
      .map((s, i) => {
        const now = i === list.length - 1 ? " byte-think-now" : "";
        return `<span class="byte-think-step${now}">${escapeHtml(s)}</span>`;
      })
      .join("");
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
    const body = container.querySelector("[data-thoughts-body]");
    if (!summary || !body) return;

    summary.textContent =
      state === "streaming"
        ? `Thinking (${list.length} step${list.length === 1 ? "" : "s"})…`
        : `Thinking (${list.length} step${list.length === 1 ? "" : "s"})`;

    const wasAtBottom =
      body.scrollHeight - body.scrollTop - body.clientHeight < 40;

    body.innerHTML = list
      .map((t) => {
        const type = t && t.type;
        const value = (t && t.value) || "";
        if (type === "tool_use") {
          return `<div class="byte-thought byte-thought-tool">🔧 ${escapeHtml(value)}</div>`;
        }
        if (type === "tool_result") {
          return `<div class="byte-thought byte-thought-result">${escapeHtml(value)}</div>`;
        }
        return `<div class="byte-thought byte-thought-text">${renderMarkdown(value)}</div>`;
      })
      .join("");

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
    const meta = message.metadata || {};
    const requestId = meta.action_request_id;
    const actionKind = meta.action_kind || "permission";
    const actionState = meta.action_state || "pending";
    const buttons = Array.isArray(meta.buttons) ? meta.buttons : [];
    const questions = Array.isArray(meta.questions) ? meta.questions : [];
    const multi = !!meta.multi_select;
    const title = meta.title || meta.tool_name || "Action";
    const subtitle = meta.subtitle || "";
    const body = message.body || "";
    const decision = meta.action_decision || {};

    const kindClass = `byte-action-kind-${actionKind}`;
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
        ${
          useQuestions
            ? renderQuestionSections(questions, actionState, decision)
            : `<div class="byte-action-buttons" role="group">${renderButtons(buttons, multi, actionState, decision)}</div>`
        }
        ${
          (useQuestions || multi) && actionState === "pending"
            ? `
          <button type="button" class="byte-action-submit" data-byte-action-submit>Submit</button>
        `
            : ""
        }
        ${
          actionState === "decided"
            ? `
          <div class="byte-action-decided">✓ decided${decision.value ? ` — ${escapeHtml(formatDecision(decision.value))}` : ""}</div>
        `
            : ""
        }
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
        if (ans && ans.header)
          decidedByHeader.set(
            ans.header,
            Array.isArray(ans.answers) ? ans.answers : [ans.answers],
          );
      });
    }

    return `<div class="byte-action-questions">
      ${questions
        .map((q, idx) => {
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
              ${opts
                .map((o) => {
                  const label = o.label ?? "";
                  const isChosen = chosenSet.has(String(label));
                  const classes = [
                    "byte-action-btn",
                    "byte-action-btn-default",
                    isChosen ? "chosen" : "",
                    disabled ? "disabled" : "",
                  ]
                    .filter(Boolean)
                    .join(" ");
                  return `
                  <button type="button" class="${classes}"
                          data-byte-question-option="${escapeAttr(label)}"
                          ${disabled ? "disabled" : ""}>
                    <span class="byte-action-btn-label">${escapeHtml(label)}</span>
                    ${o.description ? `<span class="byte-action-btn-desc">${escapeHtml(o.description)}</span>` : ""}
                  </button>
                `;
                })
                .join("")}
            </div>
          </section>
        `;
        })
        .join("")}
    </div>`;
  }

  // For multi-question, track per-question selection and only enable
  // Submit when every question has ≥1 answer.
  function wireQuestionHandlers(container, requestId, questions, actionState) {
    if (actionState !== "pending" || !requestId) return;

    // selections[i] is a Set of chosen labels for question i.
    const selections = questions.map(() => new Set());

    const sections = Array.from(
      container.querySelectorAll(".byte-action-question"),
    );
    const submit = container.querySelector("[data-byte-action-submit]");

    const updateSubmit = () => {
      const allAnswered = selections.every((s) => s.size > 0);
      if (submit) submit.disabled = !allAnswered;
    };
    if (submit) submit.disabled = true; // start off, until every question answered

    sections.forEach((section, i) => {
      const isMulti = section.dataset.multiSelect === "true";
      const optionBtns = Array.from(
        section.querySelectorAll("[data-byte-question-option]"),
      );

      optionBtns.forEach((btn) => {
        btn.addEventListener("click", () => {
          if (btn.disabled) return;
          const value = btn.dataset.byteQuestionOption;
          if (isMulti) {
            if (selections[i].has(value)) {
              selections[i].delete(value);
              btn.classList.remove("selected");
            } else {
              selections[i].add(value);
              btn.classList.add("selected");
            }
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
        Array.from(s.querySelectorAll("[data-byte-question-option]")).forEach(
          (b) => {
            b.disabled = true;
            b.classList.add("disabled");
          },
        );
      });
      // Wire shape matches Claude Code's AskUserQuestion output format:
      // [{ header, answers: [...] }, ...] — indexed to match questions order.
      const payload = questions.map((q, i) => ({
        header: q.header,
        answers: Array.from(selections[i]),
      }));
      submitAction(requestId, payload, container);
    });
  }

  function iconForKind(kind) {
    switch (kind) {
      case "plan":
        return "📋";
      case "question":
        return "?";
      case "jarvis":
        return "🎩";
      default:
        return "⚡";
    }
  }

  function renderButtons(buttons, multi, state, decision) {
    const disabled = state !== "pending";
    const chosenSet = new Set(
      Array.isArray(decision.value)
        ? decision.value.map(String)
        : decision.value != null
          ? [String(decision.value)]
          : [],
    );

    return buttons
      .map((b) => {
        const value = b.value ?? b.label;
        const isChosen = chosenSet.has(String(value));
        const variant = b.variant || "default";
        const classes = [
          "byte-action-btn",
          `byte-action-btn-${variant}`,
          isChosen ? "chosen" : "",
          disabled ? "disabled" : "",
        ]
          .filter(Boolean)
          .join(" ");
        const description = b.description
          ? `<span class="byte-action-btn-desc">${escapeHtml(b.description)}</span>`
          : "";
        return `
        <button type="button" class="${classes}" data-byte-action-value="${escapeAttr(String(value))}" ${disabled ? "disabled" : ""}>
          <span class="byte-action-btn-label">${escapeHtml(b.label ?? value)}</span>
          ${description}
        </button>
      `;
      })
      .join("");
  }

  function formatDecision(v) {
    if (Array.isArray(v)) {
      // Multi-question shape: [{header, answers}, ...]
      if (v.length && v[0] && typeof v[0] === "object" && "header" in v[0]) {
        return v
          .map(
            (ans) =>
              `${ans.header}: ${Array.isArray(ans.answers) ? ans.answers.join(", ") : ans.answers}`,
          )
          .join(" · ");
      }
      // Flat multi-select array
      return v.join(", ");
    }
    return String(v ?? "");
  }

  function wireActionHandlers(container, requestId, multi, actionState) {
    if (actionState !== "pending" || !requestId) return;

    const btns = Array.from(
      container.querySelectorAll("[data-byte-action-value]"),
    );
    const submit = container.querySelector("[data-byte-action-submit]");
    const selected = new Set();

    btns.forEach((btn) => {
      btn.addEventListener("click", () => {
        if (btn.disabled) return;
        const value = btn.dataset.byteActionValue;
        if (multi) {
          if (selected.has(value)) {
            selected.delete(value);
            btn.classList.remove("selected");
          } else {
            selected.add(value);
            btn.classList.add("selected");
          }
        } else {
          // Optimistic: dim all, mark chosen, disable further taps until the
          // server confirms (or throws).
          btns.forEach((b) => {
            b.disabled = true;
            b.classList.add("disabled");
          });
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
      btns.forEach((b) => {
        b.disabled = true;
        b.classList.add("disabled");
      });
      submitAction(requestId, Array.from(selected), container);
    });
  }

  async function submitAction(requestId, value, container) {
    try {
      const csrf =
        document
          .querySelector('meta[name="csrf-token"]')
          ?.getAttribute("content") || "";
      const res = await fetch(
        `/byte/actions/${encodeURIComponent(requestId)}/respond`,
        {
          method: "POST",
          credentials: "same-origin",
          headers: {
            "Content-Type": "application/json",
            Accept: "application/json",
            "X-CSRF-Token": csrf,
          },
          body: JSON.stringify({ value: value }),
        },
      );
      if (!res.ok) throw new Error(`http_${res.status}`);
      // The broadcast that follows will repaint the bubble with
      // action_state=decided — nothing to do here.
    } catch (e) {
      // Roll back optimistic state so the user can retry.
      Array.from(
        container.querySelectorAll("[data-byte-action-value]"),
      ).forEach((b) => {
        b.disabled = false;
        b.classList.remove("chosen", "disabled");
      });
      const sub = container.querySelector("[data-byte-action-submit]");
      if (sub) {
        sub.disabled = false;
        sub.textContent = "Submit";
      }
      const err = document.createElement("div");
      err.className = "byte-action-error";
      err.textContent = `Couldn't send: ${e.message}. Tap again.`;
      container.appendChild(err);
    }
  }

  // `live` distinguishes a paint driven by a fresh WS event (true) from
  // one driven by cache/history hydration (false). Only live paints get
  // to run the "actively streaming" cursor/pulse animations — on reload,
  // a message that the server says is state:"streaming" might be a
  // months-old orphan from a crashed process, and forcing it to spin
  // forever is the runaway-thinking-process bug the user hit.
  function upsertMessage(message, opts = {}) {
    // Buddy quick-action triggers post an outbound "message" whose only
    // purpose is to give the Mac a reply anchor. It should never render
    // as a fake user bubble — the visible thing is the Buddy reply that
    // comes back. Drop it silently if it's already mounted; skip mount
    // otherwise.
    if (message?.metadata?.hidden === true) {
      const existing = nodeForServerMessage(message);
      if (existing) existing.remove();
      return;
    }

    let node = nodeForServerMessage(message);
    if (!node) {
      node = newMessageNode();
      thread.appendChild(node);
    }
    dropDuplicatesOf(message, node);
    paintMessageNode(node, message, opts);
    reorderActiveTail();
  }

  // One node per server message, always.
  //
  // A message reaches the thread by two routes — the HTTP response to a send
  // and the WS broadcast — and the two lookups can resolve differently: one
  // finds the optimistic bubble by local_id, the other mounts a fresh node by
  // server id. Whichever arrives second then paints its own node and the same
  // message is on screen twice. Reconciling on the id here means no future
  // pairing of delivery routes can do that again.
  function dropDuplicatesOf(message, keep) {
    if (message?.id == null) return;

    thread.querySelectorAll(selectorForId(message.id)).forEach((other) => {
      if (other !== keep) other.remove();
    });
  }

  // Reorder the thread so that any "active" message (streaming response
  // or pending action-request) floats to the bottom, with streaming
  // responses above pending action-requests. Settled messages sort by
  // created_at — which, thanks to touch_created_at on finalised Claude
  // responses, places an already-answered action-request ABOVE the
  // response even when the response finished streaming first. Only
  // touches nodes from the first point of divergence onward so scroll
  // position and focus are preserved.
  function reorderActiveTail() {
    const children = Array.from(thread.children);
    const settled = [];
    const streaming = [];
    const pending = [];
    for (const n of children) {
      const kind = n.dataset.activeKind;
      // A streaming node only floats to the bottom while it's actually LIVE
      // (byte-msg-live, refreshed by fresh WS updates with a ~15s expiry). An
      // orphaned placeholder — a "…" the Mac started streaming but never
      // finalized because the turn errored — loses that class and must fall
      // back to its chronological slot, not stay pinned below newer replies.
      if (kind === "streaming" && n.classList.contains("byte-msg-live"))
        streaming.push(n);
      else if (kind === "pending") pending.push(n);
      else settled.push(n);
    }
    settled.sort((a, b) => {
      const at = Date.parse(a.dataset.createdAt || "") || 0;
      const bt = Date.parse(b.dataset.createdAt || "") || 0;
      return at - bt;
    });
    const desired = [...settled, ...streaming, ...pending];
    let i = 0;
    while (i < children.length && children[i] === desired[i]) i++;
    for (; i < desired.length; i++) {
      thread.appendChild(desired[i]);
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
    // Held client-side (offline / channel down) → render as queued, not just
    // "pending", and expose the cancel ✕ so it can be dropped before it fires.
    const held = entry.held === true;
    node.className = `byte-msg byte-msg-outbound ${held ? "byte-msg-queued" : "byte-msg-pending"}`;
    node.querySelector("[data-body]").textContent = entry.body || "";
    node.querySelector("[data-time]").textContent = formatTime(
      new Date(entry.client_ts || entry.queued_at || Date.now()).toISOString(),
    );
    // Optimistic image previews (objectURLs) while the send is in flight; the
    // server bubble replaces these with the real attachments on delivery.
    // After a reload the objectURLs are gone but the signed ids survive, so a
    // still-queued image falls back to a placeholder rather than an empty
    // bubble (which is all an image-only send would otherwise be).
    renderAttachments(
      node.querySelector("[data-attachments]"),
      entry.attachments_preview?.length
        ? entry.attachments_preview
        : (entry.attachment_signed_ids || []).map((id) => ({
            id,
            pending: true,
          })),
    );
    node.querySelector("[data-state]").textContent = held ? "queued" : "…";
    const cancelBtn = node.querySelector("[data-msg-cancel]");
    if (cancelBtn) cancelBtn.hidden = !held;
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
    const currentIds = Array.from(container.children).map(
      (el) => el.dataset.attachmentId,
    );
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
    if (a.pending) {
      // Uploaded, still waiting on its send — no local preview survived the
      // reload, so stand in for it until the server bubble arrives.
      wrap.classList.add("byte-attachment-pending");
      wrap.textContent = "image";
    } else if (type === "image") {
      const img = document.createElement("img");
      img.src = a.url;
      img.alt = a.filename || "";
      img.loading = "lazy";
      // An image finishing load grows the bubble with no DOM mutation, so the
      // growth observer can't see it — re-pin explicitly. Listener dies with
      // the node; no leak.
      img.addEventListener("load", pinToBottomSoon);
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

  // Begin/stop the load-time pin latch (see the declaration up top). Started by
  // hydrateForConversation; released on the first real user gesture or when the
  // bounded timer fires, whichever comes first.
  function beginStickThroughLoad() {
    stickThroughLoad = true;
    if (stickThroughLoadTimer) clearTimeout(stickThroughLoadTimer);
    // Bounded so we never pin forever; long enough to cover the network
    // refetch plus late layout (images, proposal cards) settling in.
    stickThroughLoadTimer = setTimeout(releaseStickThroughLoad, 1500);
  }

  function releaseStickThroughLoad() {
    stickThroughLoad = false;
    if (stickThroughLoadTimer) {
      clearTimeout(stickThroughLoadTimer);
      stickThroughLoadTimer = 0;
    }
  }

  // Pin to the bottom of the thread. "auto" runs a short settle loop that
  // re-pins over the next several frames, so late layout shifts can't
  // strand the newest content below the fold: a just-appended sent message,
  // a proposal checklist rendering in, the composer autosizing back down,
  // the mobile keyboard resizing the thread. A single double-rAF (the old
  // approach) fired once and missed anything that grew a frame later —
  // which is exactly why sending a message kept landing above the fold.
  //
  // The loop self-cancels the instant a real user scroll-up flips `atBottom`
  // false (the thread scroll listener recomputes it), so it never fights an
  // intentional scroll away from the bottom.
  function scrollToBottom(behavior = "auto") {
    atBottom = true;
    clearUnread();
    if (stickRaf) {
      cancelAnimationFrame(stickRaf);
      stickRaf = 0;
    }

    if (behavior === "smooth") {
      requestAnimationFrame(() => {
        requestAnimationFrame(() => {
          if (atBottom)
            thread.scrollTo({ top: thread.scrollHeight, behavior: "smooth" });
        });
      });
      return;
    }

    let frames = 0;
    const step = () => {
      // A real scroll-up stops us fighting — but during a conversation load the
      // atBottom heuristic flickers false while content lays out, so
      // stickThroughLoad keeps us pinning (and re-asserts the flag the growth
      // observer and refetch guard both read).
      if (!atBottom && !stickThroughLoad) {
        stickRaf = 0;
        return;
      }
      if (stickThroughLoad) atBottom = true;
      thread.scrollTop = thread.scrollHeight;
      frames += 1;
      const maxFrames = stickThroughLoad ? 24 : 8;
      stickRaf = frames < maxFrames ? requestAnimationFrame(step) : 0;
    };
    stickRaf = requestAnimationFrame(step);
  }

  function clearUnread() {
    unreadCount = 0;
    updateJumpBtn();
  }

  function updateJumpBtn() {
    if (!jumpBtn) return;
    const shouldShow = !atBottom;
    jumpBtn.classList.toggle("visible", shouldShow);
    if (jumpCount)
      jumpCount.textContent = unreadCount > 0 ? String(unreadCount) : "";
  }

  jumpBtn?.addEventListener("click", () => scrollToBottom("smooth"));

  thread.addEventListener("scroll", () => {
    atBottom = measureAtBottom();
    if (atBottom) clearUnread();
    updateJumpBtn();
    if (thread.scrollTop < LOAD_TRIGGER_PX) maybeLoadOlder();
  });

  // A real user gesture during a load means "I want to look up here" — drop the
  // load pin immediately so we stop yanking them back to the bottom. Scroll
  // events alone can't tell us this (our own pin writes fire them too), so we
  // key off the actual input devices.
  ["wheel", "touchmove", "keydown"].forEach((evt) => {
    thread.addEventListener(
      evt,
      () => {
        if (stickThroughLoad) releaseStickThroughLoad();
      },
      { passive: true },
    );
  });

  // Pin one frame from now, once, whenever thread content grows AFTER an
  // explicit scrollToBottom already ran. scrollToBottom only settles for ~8
  // frames; growth that lands later strands below the fold. Two cases the
  // user hit: (1) a multiline message we just sent finishes layout a frame or
  // two late; (2) a streaming inbound Buddy reply arrives as "…" and then
  // expands into a full multi-part message over SECONDS. Gated by `atBottom`,
  // so it never fights an intentional scroll-up. Coalesced via pinRaf so a
  // burst of streaming mutations is one scroll write per frame.
  function pinToBottomSoon() {
    // While composing, pin even if the atBottom heuristic momentarily reads
    // false (a long message rendering while the keyboard animates) — otherwise
    // its tail strands below the fold.
    if ((!atBottom && !composerFocused() && !stickThroughLoad) || pinRaf)
      return;
    pinRaf = requestAnimationFrame(() => {
      pinRaf = 0;
      if (atBottom || composerFocused() || stickThroughLoad)
        thread.scrollTop = thread.scrollHeight;
    });
  }

  // One observer on the persistent thread node (no per-message bookkeeping,
  // no leak). childList catches appended bubbles; characterData + subtree
  // catch a streaming body growing in place. Setting scrollTop mutates no
  // DOM, so this can't loop on itself.
  if (typeof MutationObserver !== "undefined") {
    new MutationObserver(pinToBottomSoon).observe(thread, {
      childList: true,
      subtree: true,
      characterData: true,
    });
  }

  // Long-press copy used to live here as its own pointerdown/move/up state
  // machine. initMessageContextMenu (below) now owns that gesture and offers
  // Copy full message alongside Copy ID, so both were bound to the same thread
  // and racing on the same hold. Its clipboard fallback and its own success /
  // failure feedback came with it, so copyText and flashToast went too.

  function receiveMessage(message) {
    const wasAtBottom = measureAtBottom();
    const isNew = !nodeForServerMessage(message);
    upsertMessage(message, { live: true });
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
    // Pin through the whole load before we disturb the thread — clearing it
    // below fires a scroll event that would otherwise flip atBottom false and
    // abort the pin, stranding a switched-into conversation at the top.
    beginStickThroughLoad();
    Array.from(
      thread.querySelectorAll("[data-message-id], [data-local-id]"),
    ).forEach((n) => n.remove());
    messages = loadMessages(convId);
    (seedMessages || []).forEach((m) => {
      messages = upsertPersisted(convId, messages, m);
    });
    oldestLoadedId = messages[0]?.id ?? null;
    hasMore = true;
    unreadCount = 0;
    // Local first so the badge clears on the tap rather than on the round trip,
    // then tell the server so it survives the next reload.
    drawerUnread.clear(convId);
    markConversationRead(convId);
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
    syncConversationChrome();
  }

  // Everything about the visible thread that ISN'T its messages: whether the
  // hero shows at all, the timer chips, the pet's whole identity, and the URL.
  //
  // Init has to run this too, and forgetting to was a bug: the server used to
  // open whichever thread had the newest message while the client restored the
  // last VIEWED one from localStorage. Those differ any time another thread got
  // a message after you left yours, so reloading a Byte thread painted it in
  // Suki's face, name, colour and favicon until you switched away and back.
  function syncConversationChrome() {
    const convo = convoManager.currentConversation();
    rememberConversationInUrl(currentConversationId);
    buddyHero?.onModeChange(convo?.mode);
    buddyTimers?.setActive();
    // Mood + theme are per-conversation — repaint the pet for the thread we're
    // on so it wears ITS face, not whichever one was painted before.
    if (convo?.mode === "buddy") applyBuddyTheme(convo);
    else wearDefaultPet();
    updateSleepChip();
  }

  // Park the open thread in the query string so the SERVER opens it on the next
  // load, rather than guessing and being corrected a moment later. That guess
  // is what put Suki's face on a Byte thread for the first paint.
  //
  // `replaceState`, not `pushState`: changing threads isn't a navigation, and
  // stacking them would turn the back button into an undo history for the
  // drawer. The hard-reload button builds its URL off location.href, so it
  // carries the thread through a cache-busting reload too.
  // The kiosk is the exception, and it matters: its URL is one of the service
  // worker's shell paths, and a query string it doesn't recognise drops the
  // page out of the cache-first branch — so writing this would cost the wall
  // tablet the offline boot, to remember a thread it can't switch away from.
  function rememberConversationInUrl(id) {
    if (!id || isKiosk) return;
    try {
      const url = new URL(location.href);
      if (url.searchParams.get("conversation_id") === String(id)) return;
      url.searchParams.set("conversation_id", String(id));
      history.replaceState(history.state, "", url);
    } catch (_) {}
  }

  // A claude or bash thread has no pet of its own, but it still has an avatar,
  // a title and a palette. Leaving the last Buddy thread's there let a Suki
  // conversation rename and recolour the whole app for threads that aren't
  // hers. The server picks the same default when it renders one of these
  // directly (see `buddy_page_theme`).
  function wearDefaultPet() {
    const chrome = buddyThemes[defaultBuddyTheme];
    if (!chrome) return;

    app.dataset.buddyTheme = defaultBuddyTheme;
    app.dataset.buddyName = chrome.name;
    document.title = chrome.name;
    paintThemeChrome(defaultBuddyTheme, chrome.name);
  }

  // Paint the whole surface + hero for a Buddy conversation's theme. Both the
  // palette (keyed off `.byte-app[data-buddy-theme]`) and the character (the
  // hero element) have to move together, or a theme change repaints the pet
  // while the surface keeps the old colour. Also restores the thread's stored
  // face. Shared by the conversation switch and a live `/buddy` theme change.
  function applyBuddyTheme(convo) {
    if (!convo) return;
    const app = document.querySelector(".byte-app");
    if (app && convo.buddy_theme) app.dataset.buddyTheme = convo.buddy_theme;
    // The pet's name rides on the wire (ByteConversation#as_wire) rather than
    // being mapped from the theme here, so the client never keeps a second copy
    // of the theme table for a new companion to fall out of date with.
    if (app && convo.buddy_name) {
      app.dataset.buddyName = convo.buddy_name;
      document.title = convo.buddy_name;
      updateSleepChip();
    }
    if (convo.buddy_theme) {
      buddyHero?.setTheme(convo.buddy_theme);
      paintThemeChrome(convo.buddy_theme, convo.buddy_name);
      warmFaces(convo.buddy_theme);
    }
    // Always derived, never inherited: a thread with no stored face used to
    // keep whatever the PREVIOUS thread was wearing, because this only
    // assigned when the incoming conversation had one.
    const expr = convo.buddy_expression;
    buddyWakeExpr =
      expr && expr !== "sleeping" ? expr : DEFAULT_WAKE_EXPRESSION;
    if (!sleepUntil) buddyHero?.setExpression(buddyWakeExpr);
  }

  // The pet's identity outside the hero: both avatars, the composer
  // placeholder, and the browser chrome. Server-rendered for the thread that
  // was open at load, so without this a switch left the previous pet's face in
  // the header and its name in the composer.
  function paintThemeChrome(theme, name) {
    const chrome = buddyThemes[theme];
    if (!chrome) return;

    const label = name || chrome.name;
    document.querySelectorAll("[data-byte-pet-avatar]").forEach((img) => {
      img.src = chrome.avatar;
      img.alt = label;
    });
    const char = document.querySelector(".byte-buddy-char");
    if (char) char.setAttribute("aria-label", label);
    if (input) input.placeholder = `Say something to ${label}…`;
    // Any static copy that names the pet — modal hints, empty states. The
    // server renders whichever thread you opened into, and switching threads
    // has to move these with it, or Suki's drawer sits there talking about Byte.
    document.querySelectorAll("[data-buddy-name-slot]").forEach((el) => {
      el.textContent = label;
    });

    setLinkHref('link[rel="icon"]', chrome.favicon);
    setLinkHref('link[rel="apple-touch-icon"]', chrome.touch_icon);
    const themeColor = document.querySelector('meta[name="theme-color"]');
    if (themeColor) themeColor.setAttribute("content", chrome.color);
    // The manifest is deliberately left alone. A PWA keeps the name and icon it
    // was installed under; rewriting the link post-load changes nothing on the
    // home screen and only risks a re-prompt.
  }

  function setLinkHref(selector, href) {
    const el = document.querySelector(selector);
    if (el && href) el.setAttribute("href", href);
  }

  // Pull a pet's face set into cache the first time you land on one of its
  // threads, so the hero's first expression change doesn't pop. The page
  // preloads only the thread it opened with — preloading all three up front is
  // forty images most sessions never look at.
  const warmedThemes = new Set();

  function warmFaces(theme) {
    if (warmedThemes.has(theme)) return;
    warmedThemes.add(theme);
    (buddyThemes[theme]?.faces || []).forEach((src) => {
      const img = new Image();
      img.decoding = "async";
      img.src = src;
    });
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
      setTimeout(() => {
        loader.hidden = true;
      }, 1500);
    } else {
      loader.hidden = true;
    }
  }

  async function maybeLoadOlder() {
    if (loadingOlder || !hasMore || !messagesUrl) return;
    if (!oldestLoadedId) return;
    if (!navigator.onLine) return;
    // Don't auto-page older history while a load is still settling to the
    // bottom — the thread transiently sits at scrollTop 0, which would
    // otherwise kick a fetch that anchors the view up top.
    if (stickThroughLoad) return;

    loadingOlder = true;
    setLoader("loading");

    const prevHeight = thread.scrollHeight;
    const prevScroll = thread.scrollTop;
    const convIdAtStart = currentConversationId;

    try {
      const url = new URL(messagesUrl, location.href);
      url.searchParams.set("before", String(oldestLoadedId));
      url.searchParams.set("conversation_id", String(convIdAtStart));
      const res = await fetch(url.toString(), {
        credentials: "same-origin",
        headers: { Accept: "application/json" },
      });
      if (!res.ok) return;

      const payload = await res.json();
      // Checked AFTER the body is parsed, not before: `res.json()` is its own
      // await, and a switch during it would have slipped past a guard placed
      // above and prepended this thread's history onto a different one.
      if (convIdAtStart !== currentConversationId) return;

      const older = Array.isArray(payload.messages) ? payload.messages : [];
      hasMore = !!payload.has_more;

      if (older.length === 0) {
        setLoader("end");
        return;
      }

      const frag = document.createDocumentFragment();
      older.forEach((m) => {
        // Only mount what isn't already on screen. This path builds nodes
        // directly rather than going through upsertMessage — it has to, to
        // prepend the whole page in one insert and keep the scroll anchored —
        // so it carries its own guard. Without it, any overlap between the
        // fetched page and what's already mounted (a repeat call, a refetch
        // that already landed) renders the same message twice.
        if (nodeForServerMessage(m)) return;

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
    try {
      return JSON.parse(raw);
    } catch {
      return {};
    }
  }

  // ---------- send ----------

  // Fire a message at a specific conversation without needing the
  // composer. Used by drawer actions (e.g. adopting a Claude session)
  // that want to auto-send a slash command straight at the target
  // thread instead of prefilling the composer for the user to submit.
  // Free the optimistic-preview objectURLs once they're no longer on screen.
  function revokePreviews(entry) {
    (entry?.attachments_preview || []).forEach((p) => {
      if (p?.url && String(p.url).startsWith("blob:"))
        URL.revokeObjectURL(p.url);
    });
  }

  // Tell the server this thread has been looked at, so the count survives a
  // reload and the home-screen badge drops with it.
  //
  // Fire-and-forget: the local badge already cleared on the tap, and a failed
  // read-marker is self-healing — the next time this conversation is opened it
  // gets marked again. Nothing here is worth blocking a switch on, and offline
  // is a normal state for this app.
  function markConversationRead(convId) {
    if (convId == null || !conversationsUrl) return;

    fetch(`${conversationsUrl}/${convId}/read`, {
      method: "POST",
      credentials: "same-origin",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token":
          document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "",
      },
    }).catch(() => {});
  }

  function sendMessageTo(convId, body, pending = null) {
    const signedIds = pending?.signed_ids || [];
    const previews = pending?.previews || [];
    if ((!body && signedIds.length === 0) || !convId) return;

    if (body === "/clear" || body === "/clear-local") {
      clearLocalState();
      return;
    }

    const local_id =
      typeof crypto !== "undefined" && crypto.randomUUID
        ? crypto.randomUUID()
        : `l-${Date.now()}-${Math.random().toString(36).slice(2)}`;

    const client_ts = Date.now();

    // Hold Buddy sends while the realtime channel is down: they sit in the
    // queue (visibly, with a cancel ✕) and drain on reconnect, rather than
    // firing into a channel Byte can't hear. Non-buddy modes keep the old
    // fire-immediately behaviour (offline durability still applies).
    const held = conversationMode(convId) === "buddy" && !channelConnected;

    const entry = {
      local_id,
      conversation_id: convId,
      body,
      client_ts,
      held,
      // Signed ids of images already uploaded to /byte/uploads. Persisted in
      // the offline queue (plain strings). `attachments_preview` carries local
      // objectURLs for the optimistic bubble only — NOT persisted, since a
      // reloaded page can't resurrect an objectURL (the send still works: the
      // server echoes the real attachment on delivery).
      attachment_signed_ids: signedIds,
      attachments_preview: previews,
      metadata: { source: "web", local_id, client_ts, conversation_id: convId },
    };

    sendMessage(
      entry,
      {
        onEnqueued: (e) => {
          if (e.conversation_id !== currentConversationId) return;
          upsertQueuedMessage(e);
          scrollToBottom("auto");
        },
        onSending: (e) => {
          if (e.conversation_id === currentConversationId)
            markQueuedSending(e.local_id);
        },
        onSent: (e, message) => {
          message = adoptSendResponse(e, message);
          // Even for background conversations, persist the resolved message
          // so its cache stays fresh; only paint into the DOM for the
          // currently-visible thread.
          const targetConv = e.conversation_id || currentConversationId;
          messages =
            targetConv === currentConversationId
              ? upsertPersisted(currentConversationId, messages, message)
              : upsertPersisted(targetConv, loadMessages(targetConv), message);
          if (targetConv === currentConversationId)
            upsertMessage(message, { live: true });
          convoManager.bumpActivity(targetConv, message.created_at);
          // The server bubble now carries the real (rails_blob_path) image
          // URLs, so the optimistic objectURLs are done — free them.
          revokePreviews(e);
        },
        onTransientFail: () => {},
        onPermanentFail: (e, reason) => {
          if (e.conversation_id === currentConversationId)
            markQueuedFailed(e.local_id, reason);
          // Give up on the send, give up on its previews — nothing will repaint
          // this bubble again, so holding the objectURLs just leaks them.
          revokePreviews(e);
        },
      },
      { hold: held },
    );
  }

  // Mode for a conversation id — from the manager's list, falling back to the
  // active-mode marker for the currently-visible thread.
  function conversationMode(convId) {
    const c = convoManager.conversations?.find((x) => x.id === convId);
    if (c) return c.mode;
    return convId === currentConversationId ? app.dataset.activeMode : null;
  }

  // Cancel ✕ on a held message. Server-queued (real id, Buddy asleep) → ask
  // the server to drop it before the wake-drain; client-held (local only,
  // channel down) → pull it straight out of the local queue.
  thread.addEventListener("click", (e) => {
    const btn = e.target.closest("[data-msg-cancel]");
    if (!btn) return;
    const node = btn.closest(".byte-msg");
    if (!node) return;
    const msgId = node.dataset.messageId;
    const localId = node.dataset.localId;
    node.remove();
    if (msgId) {
      messages = removePersisted(
        currentConversationId,
        messages,
        Number(msgId),
      );
      cancelServerMessage(msgId);
    } else if (localId) {
      removeQueued(localId);
    }
  });

  async function cancelServerMessage(msgId) {
    try {
      const csrf =
        document
          .querySelector('meta[name="csrf-token"]')
          ?.getAttribute("content") || "";
      await fetch(`/byte/messages/${encodeURIComponent(msgId)}`, {
        method: "DELETE",
        credentials: "same-origin",
        headers: { "X-CSRF-Token": csrf, Accept: "application/json" },
      });
    } catch (_) {
      /* optimistically removed already; server broadcast reconciles */
    }
  }

  async function handleSend(rawBody) {
    const body = rawBody.trim();
    // An image with no caption is a valid send. Nothing typed AND nothing
    // attached (ready or still going up) is a no-op.
    if (
      !body &&
      !composerAttachments.hasReady() &&
      !composerAttachments.isUploading()
    )
      return;
    input.value = "";
    // Clear any brain-dump capture hint once the idea (or any message) is sent.
    if (originalPlaceholder != null) input.placeholder = originalPlaceholder;
    autosize();
    armIdleFaceReset(); // sending is activity
    // The composer clears instantly, but the send itself waits on any image
    // still uploading — otherwise the caption goes without the picture it was
    // written about, and the chip is stranded in the tray with no explanation.
    if (composerAttachments.isUploading()) await composerAttachments.settled();
    const pending = composerAttachments.commit();
    sendMessageTo(currentConversationId, body, pending);
  }

  // Mount the Buddy hero once the composer + input handles exist. The
  // hero only shows itself on :buddy conversations; its quick-action
  // chips POST to /buddy/quick_action so the resulting message is
  // Buddy-authored rather than a fake user-typed sentence.
  buddyHero = initBuddyHero({
    hero: heroEl,
    conversationIdFn: () => currentConversationId,
    // Brain-dump: after a bucket is picked, hint in the composer that the next
    // message is the idea being stashed. Reset on send (see handleSend).
    onStashArmed: (category) => {
      const label =
        { me: "Me", home: "Home", work: "Work", anything: "Buddy to sort" }[
          category
        ] || category;
      input.placeholder = `Dump your idea (→ ${label})…`;
      input.focus();
    },
  });

  // Buddy timer chips (top-left under the nav). Server-authoritative countdowns
  // that ride the existing Timer stack; this just renders + reconciles them.
  const buddyTimers = initBuddyTimers({
    container: app.querySelector("[data-buddy-timers]"),
    hero: buddyHero,
    isBuddyActiveFn: () => convoManager.currentConversation()?.mode === "buddy",
  });

  // Routines and reminders: two managers reached from the drawer, each in its
  // own dialog. Fetched when the drawer opens rather than at boot — most
  // sessions never open it, and a stale list would be worse than no list. The
  // counts on the drawer rows come from the same fetch, so opening the drawer
  // is what fills them in.
  //
  // `document`, not `app`: the drawer and the dialogs are SIBLINGS of
  // .byte-app, not children of it (fixed-position, mounted outside the grid).
  // Scoping the lookup to the app returned null and the panel silently never
  // mounted, no matter how many routines you had.
  function paintCount(selector) {
    const el = document.querySelector(selector);
    return (n) => {
      if (el) el.textContent = n > 0 ? String(n) : "";
    };
  }

  const buddyRoutines = initBuddyRoutines({
    panel: document.querySelector("[data-byte-routines]"),
    list: document.querySelector("[data-byte-routine-list]"),
    empty: document.querySelector("[data-byte-routines-empty]"),
    indexUrl: "/buddy/routines",
    onCount: paintCount("[data-byte-routines-count]"),
    addBtn: document.querySelector("[data-byte-add-jil]"),
    picker: document.querySelector("[data-byte-jil-picker]"),
    pickerList: document.querySelector("[data-byte-jil-list]"),
    pickerEmpty: document.querySelector("[data-byte-jil-empty]"),
    pickerSearch: document.querySelector("[data-byte-jil-search]"),
  });
  const buddyReminders = initBuddyReminders({
    list: document.querySelector("[data-byte-reminder-list]"),
    empty: document.querySelector("[data-byte-reminders-empty]"),
    indexUrl: "/buddy/reminders",
    onCount: paintCount("[data-byte-reminders-count]"),
  });
  document
    .querySelector("[data-byte-drawer-toggle]")
    ?.addEventListener("click", () => {
      buddyRoutines?.refresh();
      buddyReminders?.refresh();
    });

  // Each row opens its dialog and re-fetches: the drawer may have been sitting
  // open a while, and a reminder that fired in the meantime shouldn't still be
  // listed when you finally look.
  function wireManager(openSel, closeSel, modalSel, manager) {
    const modal = document.querySelector(modalSel);
    if (!modal) return;

    document.querySelector(openSel)?.addEventListener("click", () => {
      manager?.refresh();
      if (typeof modal.showModal === "function") modal.showModal();
      else modal.setAttribute("open", "");
    });
    document
      .querySelector(closeSel)
      ?.addEventListener("click", () => modal.close());
  }

  wireManager(
    "[data-byte-open-routines]",
    "[data-byte-routines-close]",
    "[data-byte-routines-modal]",
    buddyRoutines,
  );
  wireManager(
    "[data-byte-open-reminders]",
    "[data-byte-reminders-close]",
    "[data-byte-reminders-modal]",
    buddyReminders,
  );
  // No manager to refresh — the only control in here reads its value from the
  // DOM, which applyFontScale already keeps current.
  wireManager(
    "[data-byte-open-settings]",
    "[data-byte-settings-close]",
    "[data-byte-settings-modal]",
    null,
  );

  // The wall-tablet surface. Only mounts when the page rendered it, so this is
  // null everywhere else and every call below is a no-op. It needs
  // renderMarkdown because a receipt bolds the thing it acted on, and the
  // bubble is the only place that text is read here; and it needs the theme
  // table plus `switchTo` because choosing which companion is on the wall is
  // choosing a thread, which repaints the pet through the ordinary switch.
  buddyKiosk = initBuddyKiosk({
    root: app.querySelector("[data-byte-kiosk]"),
    conversationIdFn: () => currentConversationId,
    conversationsFn: () => convoManager.conversations,
    themes: buddyThemes,
    switchTo: (id) => convoManager.switchTo(id),
    renderMarkdown,
  });
  buddyKiosk?.sync(messages);

  // Timer broadcasts carry `id: :timers`, and the Monitor dispatcher routes
  // envelopes by their id — so they arrive on a DEDICATED subscription, not the
  // byte one above. Mirrors how the Timers app subscribes. Hydrate on (re)connect
  // so a timer set while we were away shows up.
  Monitor.subscribe("timers", {
    connected() {
      buddyTimers?.hydrate();
    },
    received(payload) {
      buddyTimers?.applyBroadcast(payload);
    },
  });

  // Header sound toggle (Buddy's own mute, matching Whisper's control). Paints
  // the button state and silences a ringing alarm on mute.
  const muteBtn = app.querySelector("[data-byte-mute]");
  const paintMute = () => {
    muteBtn?.classList.toggle("muted", isBuddyMuted());
    if (muteBtn) {
      muteBtn.title = isBuddyMuted()
        ? "Sound off — tap to enable"
        : "Sound on — tap to mute";
    }
  };
  muteBtn?.addEventListener("click", () => {
    toggleBuddyMuted();
    paintMute();
  });
  paintMute();

  // Buddy naps while the realtime channel is down. The hero renders
  // `sleeping` by default (server-side), so a broken/absent JS bundle
  // leaves Byte honestly asleep instead of fake-awake. Once the Monitor
  // channel connects we wake it to its stored mood; a drop puts it back
  // to sleep. `buddyWakeExpr` tracks the latest real (non-connection)
  // expression so a reconnect restores the right face.
  let buddyWakeExpr = DEFAULT_WAKE_EXPRESSION;

  // Idle face reset: after 10 minutes of no activity, let Buddy's face settle
  // back to its neutral resting default (a mood shouldn't linger forever with
  // nothing happening). Re-armed on every message, expression change, or
  // interaction; firing also updates buddyWakeExpr so a reconnect doesn't
  // restore the stale mood.
  const IDLE_FACE_MS = 10 * 60 * 1000;
  let idleFaceTimer = 0;
  const armIdleFaceReset = () => {
    if (idleFaceTimer) clearTimeout(idleFaceTimer);
    idleFaceTimer = window.setTimeout(() => {
      buddyWakeExpr = "neutral";
      buddyHero?.setExpression("neutral");
    }, IDLE_FACE_MS);
  };

  const buddyWake = () => {
    // Don't wake the face while Buddy is still usage-capped — a channel
    // reconnect shouldn't flip the pet from sleeping back to its mood when
    // it's actually still asleep. (usageCapped is defined below; resolved at
    // call time.)
    if (usageCapped()) {
      buddySleep();
      return;
    }
    buddyHero?.setExpression(buddyWakeExpr);
    armIdleFaceReset();
  };
  // Sleeping repaints the pet, which also drops any transient "thinking"
  // overlay — so a turn that fails (Mac unreachable) doesn't leave Byte stuck
  // mid-thought. The stored mood lives in buddyWakeExpr and is restored on wake.
  const buddySleep = () => buddyHero?.setExpression("sleeping");
  armIdleFaceReset(); // start the idle clock on load

  // ---------- sleeping chip + queue-while-asleep ----------
  //
  // Two ways Buddy is "asleep": a server usage-cap (buddy_sleep broadcast /
  // bootstrap, carries a wake time) or the realtime channel being down
  // (channelConnected=false, no wake time). Either raises a persistent chip
  // above the composer and holds new Buddy sends in the queue with a cancel
  // ✕, until Byte wakes. (channelConnected / sleepUntil / sleepWake are
  // declared in the early-state block above to avoid a TDZ.)
  const usageCapped = () =>
    sleepUntil != null && new Date(sleepUntil).getTime() > Date.now();
  const onBuddyConversation = () =>
    (convoManager.currentConversation()?.mode || app.dataset.activeMode) ===
    "buddy";
  // Buddy can't hear you when the channel is down OR it's usage-capped.
  const buddyAsleep = () => !channelConnected || usageCapped();

  function updateSleepChip() {
    if (!sleepChip) return;
    // The chip is a Buddy concept; never show it on claude/bash/jarvis.
    const show = onBuddyConversation() && buddyAsleep();
    sleepChip.hidden = !show;
    if (!show) return;
    const who = buddyName();
    if (usageCapped()) {
      sleepText.textContent = sleepWake
        ? `${who}'s asleep until ${sleepWake}`
        : `${who}'s asleep`;
    } else {
      sleepText.textContent = `${who}'s asleep — reconnecting…`;
    }
  }

  // Dress the page for the thread we actually opened into. Deliberately down
  // here rather than beside the hydrate up top: this reaches the hero, the
  // timer chips, `buddyWakeExpr` and the sleep chip, none of which exist yet at
  // that point, and a `let` read before its declaration throws. Nothing paints
  // between the two - init is one synchronous run - so late costs nothing.
  syncConversationChrome();

  function clearLocalState() {
    clearAllPersisted();
    clearQueue();
    messages = [];
    Array.from(
      thread.querySelectorAll("[data-message-id], [data-local-id]"),
    ).forEach((n) => n.remove());
    unreadCount = 0;
    updateJumpBtn();
    refetchHistory();
    scrollToBottom("auto");
  }

  // Slash autocomplete has to bind BEFORE the composer's Enter-to-send
  // listener so it can `stopImmediatePropagation` when it consumes Enter
  // to complete a command (otherwise the completed verb gets sent as a
  // message before the user has typed the args).
  setupSlashAutocomplete({
    input,
    popover: app.querySelector("[data-byte-slash-popover]"),
    autosize: () => autosize(),
    // Read for the live mode + owner flag, so the offered commands narrow to
    // whatever the thread on screen can actually do.
    app,
  });

  // Composer image attachments — file picker, paste, and drag-drop. Uploads
  // each image to /byte/uploads and holds the signed id; handleSend pulls the
  // ready ones out via commit(). Notices (bad type, too big, upload failure)
  // surface as a local system bubble.
  const composerAttachments = initComposerAttachments({
    composer,
    input,
    thread,
    tray: app.querySelector("[data-byte-attach-tray]"),
    fileInput: app.querySelector("[data-byte-file]"),
    attachBtn: app.querySelector("[data-byte-attach]"),
    onNotice: (msg) => surfaceLocal(msg),
  });

  // Long-press / right-click a message bubble → Copy ID / Copy full message /
  // Report a problem.
  initMessageContextMenu(thread, app, { onNotice: (msg) => surfaceLocal(msg) });

  composer.addEventListener("submit", (e) => {
    e.preventDefault();
    handleSend(input.value);
  });

  // iOS reliability: tapping Send while the textarea is focused would first
  // blur the input — the keyboard retracts, the composer shifts down, and the
  // button slides out from under the finger, so the click never lands and the
  // message (often a slash command, since that's when the popover adds height)
  // silently doesn't send. Preventing the button's pointerdown default keeps
  // the input focused: the tap reliably submits and the keyboard stays up for
  // rapid sends. The click→submit still fires (only focus-steal is cancelled).
  const sendBtn = composer.querySelector("[data-byte-send]");
  sendBtn?.addEventListener("pointerdown", (e) => e.preventDefault());

  // Two-part Enter → send. Historically the single keydown handler used
  // `!e.isComposing` as an IME guard, but iOS's predictive-text state
  // marks compositions inconsistently — sometimes an Enter press comes
  // through with isComposing:true and our handler no-ops, letting the
  // textarea insert a newline instead of sending. Result: intermittent
  // "sometimes it sends, sometimes it makes a new line" experience.
  //
  // Fix: keep the keydown handler (fast path for physical keyboards
  // where Shift+Enter should insert a newline), AND add a `beforeinput`
  // backstop that catches the iOS software-keyboard case where keydown
  // Enter didn't reach us. `insertLineBreak` is fired reliably on all
  // platforms for the "user pressed the Return key" intent — intercept
  // that and submit instead.
  // Consistent Enter behavior across devices, WITH newline support:
  //
  //   Desktop keyboard:
  //     Enter        → submit
  //     Shift+Enter  → newline (default browser behavior; we don't touch it)
  //
  //   Mobile / iOS software keyboard:
  //     Return       → newline (no forced-submit hijack; textarea default)
  //     Send button  → submit (tap the .byte-send button in the composer)
  //
  // Previous version forcibly submitted on `insertLineBreak` beforeinput,
  // which blocked all newline insertion on iOS (where that event fires for
  // every Return press). Removed. Physical keyboards still get the fast
  // Enter=submit path via keydown; mobile users tap the Send button.
  // Enter-to-send is a terminal (bash) affordance only — it's a REPL, so
  // Return runs the command. Every other mode (claude, jarvis, buddy) treats
  // Return as a newline and sends via the Send button; Shift+Enter is always
  // a newline. Keyed off mode, not device, so it's consistent across desktop
  // and the mobile PWA. `composer.dataset.mode` is kept current on every
  // conversation switch (conversations.js) for the avatar/CSS, so it's a
  // reliable live source here too.
  // Enter-to-send. Bash (a REPL) submits on Enter in every environment.
  // Otherwise:
  //   * Desktop (a fine pointer ≈ a physical keyboard): Enter submits,
  //     Shift+Enter inserts a newline.
  //   * Mobile / touch: Enter is ALWAYS a newline — users send via the Send
  //     button — so we never hijack it and the software keyboard / its return
  //     key (enterkeyhint) are left exactly as they were.
  // `(pointer: fine)` is the desktop signal, read live so it tracks the
  // environment (e.g. an iPad that gains a trackpad keyboard). isComposing
  // guards IME / predictive-text Enters.
  const hasFinePointer = () =>
    typeof window.matchMedia === "function" &&
    window.matchMedia("(pointer: fine)").matches;
  input.addEventListener("keydown", (e) => {
    if (e.key !== "Enter" || e.shiftKey || e.isComposing) return;
    if (composer.dataset.mode === "bash" || hasFinePointer()) {
      e.preventDefault();
      handleSend(input.value);
    }
  });

  // Type-anywhere: if the composer ISN'T focused and the person starts typing a
  // real character (no ctrl/meta/alt, not Enter/arrows/etc.), route it into the
  // composer and focus — so keystrokes land where they expect instead of
  // vanishing. Ignored while another field/editable is focused.
  const isEditableTarget = (el) =>
    el &&
    (el.tagName === "INPUT" ||
      el.tagName === "TEXTAREA" ||
      el.tagName === "SELECT" ||
      el.isContentEditable);
  document.addEventListener("keydown", (e) => {
    if (e.defaultPrevented) return;
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key == null || e.key.length !== 1) return; // printable single chars only
    if (document.activeElement === input) return;
    if (isEditableTarget(document.activeElement)) return;
    e.preventDefault();
    input.value += e.key;
    input.focus();
    autosize();
  });

  // Click-anywhere-to-focus (mouse only — a mobile TAP shouldn't pop the
  // keyboard unexpectedly). Clicking empty space in the thread focuses the
  // composer; interactive elements and active text selections are left alone.
  thread.addEventListener("click", (e) => {
    if (!hasFinePointer()) return;
    // `select` belongs here for the same reason every other control does, and
    // its absence was invisible until forms in the thread started carrying
    // dropdowns. On desktop the click bubbled up, the composer took focus, and
    // the native popup closed in the same frame it opened — so a "Who did it?"
    // could be opened and never picked from. isEditableTarget above has always
    // counted SELECT; this list simply didn't.
    if (
      e.target.closest(
        "button, a, input, select, textarea, label, [role='button']",
      )
    )
      return;
    const sel = window.getSelection && window.getSelection();
    if (sel && sel.toString().length > 0) return; // don't steal focus mid-selection
    input.focus();
  });

  // The Buddy hero grows/shrinks over a 220ms CSS transition when the
  // composer gains/loses focus (the mobile keyboard opening/closing). That
  // resizes the thread AFTER any immediate scrollToBottom already ran,
  // stranding the newest message off-screen. Re-pin to the bottom when the
  // transition settles, and directly on focus/blur.
  const repinIfAtBottom = () => {
    if (atBottom || composerFocused()) scrollToBottom("auto");
  };
  heroEl?.addEventListener("transitionend", (e) => {
    if (e.propertyName === "min-height" || e.propertyName === "max-height")
      repinIfAtBottom();
  });
  // Focusing the composer (keyboard opening) always snaps to the bottom, no
  // matter where the reader was — that's the whole point of tapping to type.
  input.addEventListener("focus", () => {
    scrollToBottom("auto");
    armIdleFaceReset(); // interacting with the composer is activity
  });
  input.addEventListener("blur", repinIfAtBottom);

  function autosize() {
    input.style.height = "auto";
    input.style.height =
      Math.min(input.scrollHeight, window.innerHeight * 0.3) + "px";
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

  // Bigger than any URL bar, smaller than any keyboard. See setAppHeight.
  const STALE_VIEWPORT_GAP = 160;

  // ---- reader font size ----
  //
  // One multiplier, bound to `.byte-msg` in CSS. The server renders the saved
  // value inline so the first paint is already right; this is for changes made
  // after that, from the stepper or from Buddy.
  const FONT_MIN = 80;
  const FONT_MAX = 200;
  const FONT_STEP = 10;

  function applyFontScale(scale) {
    const pct = Math.min(FONT_MAX, Math.max(FONT_MIN, Number(scale) || 100));
    app.style.setProperty("--byte-font-scale", String(pct / 100));
    app.dataset.fontScale = String(pct);
    const out = document.querySelector("[data-byte-font-value]");
    if (out) out.textContent = `${pct}%`;
    // The bubbles just changed height, so whoever was reading the newest
    // message should still be looking at it.
    if (atBottom) scrollToBottom("auto");
    return pct;
  }

  async function nudgeFontScale(delta) {
    const url = app.dataset.fontScaleUrl;
    if (!url) return;

    const next = applyFontScale(Number(app.dataset.fontScale || 100) + delta);
    try {
      await fetch(url, {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token":
            document
              .querySelector('meta[name="csrf-token"]')
              ?.getAttribute("content") || "",
        },
        body: JSON.stringify({ scale: next }),
      });
    } catch (_e) {
      // Optimistic on purpose: the size already changed on screen, and a failed
      // save costs them one tap next time rather than a snap-back mid-read.
    }
  }

  applyFontScale(app.dataset.fontScale || 100);
  document
    .querySelector("[data-byte-font-smaller]")
    ?.addEventListener("click", () => nudgeFontScale(-FONT_STEP));
  document
    .querySelector("[data-byte-font-bigger]")
    ?.addEventListener("click", () => nudgeFontScale(FONT_STEP));

  // Any focused editable, not just the composer — a form field inside a
  // message opens the keyboard too, and treating that as "no keyboard" would
  // fight the real one.
  const typingSomewhere = () => {
    const el = document.activeElement;
    if (!el || el === document.body) return false;

    return (
      el.isContentEditable ||
      ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName)
    );
  };

  let rafH = 0;
  const setAppHeight = () => {
    if (rafH) return;
    rafH = requestAnimationFrame(() => {
      rafH = 0;
      const wh = window.innerHeight;
      const vvh = window.visualViewport
        ? Math.round(window.visualViewport.height)
        : null;
      // Prefer visualViewport.height when available — it always matches
      // the visible viewport (excludes keyboard). window.innerHeight can
      // report the LAYOUT viewport on some iOS PWA configurations,
      // which is bigger than what's visible when the keyboard is up.
      // ...but a keyboard that closed while the app was BACKGROUNDED never
      // fires a resize, so on resume visualViewport can still be reporting the
      // keyboard-sized viewport. That left the composer stranded mid-screen
      // with no keyboard under it and nothing to nudge it back.
      //
      // Nothing focused means no keyboard, so a viewport that's dramatically
      // shorter than the window is a stale reading and the window wins. The
      // threshold is well past any URL bar (~100px) and well under any
      // keyboard (~300px), so this only ever fires on the stale case.
      const stale =
        vvh != null && !typingSomewhere() && wh - vvh > STALE_VIEWPORT_GAP;
      const h = (stale ? wh : vvh) || wh;
      document.documentElement.style.setProperty("--byte-app-h", `${h}px`);
      // Debug: publish to the drawer footer so misreports are visible.
      const setV = (sel, val) => {
        const el = document.querySelector(sel);
        if (el) el.textContent = val;
      };
      setV("[data-byte-version-apph]", `${h}`);
      setV("[data-byte-version-vvh]", vvh != null ? `${vvh}` : "n/a");
      setV("[data-byte-version-winh]", `${wh}`);

      // The thread's height is bound to --byte-app-h, so this resize just
      // shrank/grew the scroll viewport (keyboard opening/closing, URL bar,
      // rotation). If we were pinned to the bottom, re-pin — otherwise the
      // keyboard opening leaves you scrolled a couple messages up from the
      // newest one. iOS fires these visualViewport events repeatedly across
      // the keyboard animation, so each one re-pins and the bottom tracks
      // the shrink smoothly. Gated on atBottom so a scrolled-up reader is
      // left where they are — EXCEPT while composing, where we force the pin
      // so the keyboard shrinking the viewport can't strand the thread above
      // it (the bug: keyboard covering the messages / long message below view).
      if (atBottom || composerFocused()) scrollToBottom("auto");
    });
  };
  setAppHeight();
  window.addEventListener("resize", setAppHeight);
  window.addEventListener("orientationchange", setAppHeight);
  window.visualViewport?.addEventListener("resize", setAppHeight);
  // Also re-measure on scroll and focus/blur — iOS fires visualViewport
  // scroll BEFORE resize in some keyboard transitions.
  window.visualViewport?.addEventListener("scroll", setAppHeight);
  window.addEventListener("focusin", setAppHeight);
  window.addEventListener("focusout", setAppHeight);

  // Coming back from the background. iOS suspends the page, so a keyboard
  // dismissed while away produces no event at all — without this the app
  // repaints at whatever height it was frozen at. Measured several times
  // because the first reading after a resume is often still the old one, and
  // the viewport settles over a few hundred milliseconds.
  const remeasureAfterResume = () => {
    setAppHeight();
    [60, 250, 600].forEach((ms) => setTimeout(setAppHeight, ms));
  };
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) remeasureAfterResume();
  });
  window.addEventListener("pageshow", remeasureAfterResume);

  // Layout-viewport-scroll compensator (unchanged) — no height side-effect.
  if (window.visualViewport) {
    const vv = window.visualViewport;
    let rafId = 0;
    const applyTop = () => {
      if (rafId) return;
      rafId = requestAnimationFrame(() => {
        rafId = 0;
        if (vv.offsetTop > 0) {
          document.documentElement.style.setProperty(
            "--byte-vv-top",
            `${vv.offsetTop}px`,
          );
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
        if (e.conversation_id === currentConversationId)
          markQueuedSending(e.local_id);
      },
      onSent: (e, message) => {
        message = adoptSendResponse(e, message);
        const targetConv = e.conversation_id || currentConversationId;
        if (targetConv === currentConversationId) {
          messages = upsertPersisted(currentConversationId, messages, message);
          upsertMessage(message, { live: true });
        } else {
          upsertPersisted(targetConv, loadMessages(targetConv), message);
        }
        convoManager.bumpActivity(targetConv, message.created_at);
      },
      onPermanentFail: (e, reason) => {
        if (e.conversation_id === currentConversationId)
          markQueuedFailed(e.local_id, reason);
      },
    };
  }

  function scheduleDrain() {
    if (!navigator.onLine) return;
    drainQueue(drainHooks());
  }

  let hasBeenConnected = false;
  let wasDisconnected = false;

  Monitor.subscribe(monitorChannel, {
    connected() {
      setStatus("connected", "connected");
      channelConnected = true;
      buddyWake();
      updateSleepChip();
      // Reconnected: drain anything held while the channel was down.
      scheduleDrain();
      refetchHistory();
      convoManager.refresh().catch(() => {});
      if (hasBeenConnected && wasDisconnected) {
        requestShellRefresh();
        checkForServiceWorkerUpdate();
      }
      hasBeenConnected = true;
      wasDisconnected = false;
    },
    disconnected() {
      setStatus("disconnected", "disconnected");
      channelConnected = false;
      buddySleep();
      updateSleepChip();
      wasDisconnected = true;
    },
    received(payload) {
      const data = payload?.data;
      if (!data) return;
      if (data.kind === "conversation") {
        convoManager.applyBroadcast(data);
        updateSleepChip(); // mode may have changed under the active thread
        // A live theme swap (`/buddy suki`) on the thread on screen has to
        // repaint the surface + pet now — applyBroadcast only touches the list.
        const convo = data.conversation;
        if (
          convo &&
          convo.id === currentConversationId &&
          convo.mode === "buddy"
        ) {
          applyBuddyTheme(convo);
        }
        return;
      }
      if (data.kind === "buddy_expression") {
        // Mood is per-conversation now. Ignore a face broadcast for a thread
        // that isn't the one on screen — otherwise conversation A's mood would
        // paint over conversation B's pet.
        if (
          data.conversation_id != null &&
          data.conversation_id !== currentConversationId
        )
          return;
        if (data.transient) {
          // A transient overlay (e.g. "thinking"). Show it, but DON'T remember
          // it as the mood — when it clears we fall back to the real face.
          buddyHero?.setExpression(data.expression, { transient: true });
        } else {
          // A real mood change. Remember it as the wake/rest target so a later
          // reconnect restores this face rather than a stale one.
          buddyWakeExpr = data.expression;
          buddyHero?.setExpression(data.expression);
        }
        armIdleFaceReset(); // a face change is activity — restart the idle clock
        return;
      }
      if (data.kind === "buddy_sleep") {
        // Buddy went to sleep — either a usage cap OR the Mac being unreachable
        // (TurnDispatcher sleeps on a failed deliver). Raise the chip AND put
        // the pet visibly to sleep: that clears the optimistic "thinking" face
        // the send set, so a failed turn reads as "asleep / can't reach me"
        // instead of leaving Byte stuck mid-thought.
        sleepUntil = data.sleep_until || null;
        sleepWake = data.wake_string || null;
        updateSleepChip();
        buddySleep();
        return;
      }
      if (data.kind === "buddy_wake") {
        // Byte woke — drop the chip and bring the face back to its mood.
        // Queued turns re-broadcast as they dispatch (queued → sent), so their
        // bubbles resolve on their own.
        sleepUntil = null;
        sleepWake = null;
        updateSleepChip();
        buddyWake();
        return;
      }
      if (data.kind === "font_scale") {
        // Buddy changed it ("make the text bigger"). Apply here rather than
        // waiting for a reload — the whole point is that they see it happen.
        applyFontScale(data.scale);
        return;
      }
      if (data.kind === "message_deleted") {
        // Server deleted a message (e.g. Buddy side-effect-only reply
        // with no prose - the bubble had nothing to show). Remove
        // from cache + DOM so the user doesn't see a ghost.
        const convId = data.byte_conversation_id;
        const msgId = data.message_id;
        if (convId != null && msgId != null) {
          const targetList =
            convId === currentConversationId ? messages : loadMessages(convId);
          const updated = removePersisted(convId, targetList, msgId);
          if (convId === currentConversationId) {
            messages = updated;
            const node = thread.querySelector(selectorForId(msgId));
            node?.remove();
          }
        }
        return;
      }
      if (data.kind === "message" && data.message) {
        const msg = data.message;
        const convId = msg.conversation_id;
        // Persist to the message's conversation cache regardless of what's
        // currently visible — a background thread might get updated while
        // the user is looking at another one.
        if (convId != null) {
          const targetList =
            convId === currentConversationId ? messages : loadMessages(convId);
          const updated = upsertPersisted(convId, targetList, msg);
          if (convId === currentConversationId) messages = updated;
        }
        if (convId === currentConversationId) {
          receiveMessage(msg);
          // Buddy's reply text just started (or grew): drop the "thinking"
          // overlay and, if the reply opens with a [[mood:]], wear that face as
          // the words begin. onReplyStreaming filters out the "…" placeholder
          // and non-reply chips, so the pet keeps thinking until REAL words
          // stream — not the moment a placeholder/chip lands.
          if (msg.direction === "inbound") buddyHero?.onReplyStreaming(msg);
          // The kiosk has no thread to read this in, so it's the bubble over
          // the pet or the question card over the buttons.
          buddyKiosk?.onLive(msg);
          armIdleFaceReset(); // a new message is activity
        } else if (drawerUnread.add(convId, msg)) {
          // Genuinely new and genuinely settled — `add` returns false for a
          // re-broadcast of something already counted, and for anything still
          // streaming, so a working Claude turn stays silent until it speaks.
          const chrome = convoManager.chromeFor(convId);
          unreadNotices.notify({
            convId,
            title: chrome?.name || "New message",
            body: previewOf(msg),
            icon: chrome?.icon || null,
          });
        }
        if (msg.created_at) convoManager.bumpActivity(convId, msg.created_at);
      }
    },
  });

  setInterval(
    () => {
      requestShellRefresh();
      checkForServiceWorkerUpdate();
    },
    5 * 60 * 1000,
  );

  window.addEventListener("online", scheduleDrain);
  window.addEventListener("focus", scheduleDrain);

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
      const payload = await res.json();
      // After the parse, not before — `res.json()` is its own await, and a
      // switch during it used to land this thread's history in the cache and
      // the DOM of whichever thread you'd moved to.
      if (convIdAtStart !== currentConversationId) return;

      const latest = Array.isArray(payload.messages) ? payload.messages : [];
      if (typeof payload.has_more === "boolean") hasMore = payload.has_more;
      if (!oldestLoadedId && latest[0]) oldestLoadedId = latest[0].id;
      const wasAtBottom = atBottom;
      latest.forEach((m) => {
        messages = upsertPersisted(convIdAtStart, messages, m);
        upsertMessage(m);
      });
      // Silently, so a reconnect doesn't replay an hour-old line — but an
      // unanswered question has to come back, or a sequence that stopped for
      // one is stranded with nothing on screen to finish it.
      buddyKiosk?.sync(messages);
      // `|| stickThroughLoad`: on a fresh switch the real messages arrive here
      // (empty cache), after the transient that already flipped wasAtBottom
      // false — so honor the load latch and pin regardless.
      if (wasAtBottom || stickThroughLoad) scrollToBottom("auto");
    } catch (_) {}
  }

  // Presence heartbeat. Tells Rails "user is looking at Byte right now"
  // so the webhook can skip firing a push notification. iOS would render
  // the push as an OS banner even if the SW tried to suppress it (Web
  // Push spec's userVisibleOnly forces a notification), so the ONLY
  // reliable way to avoid double-alerts is to not send the push at all.
  let presenceInterval = 0;
  // Resolved once and reused: it identifies this DEVICE to the presence
  // endpoint, so a window that can receive pushes can say it is looking and
  // a window that cannot stays out of the decision entirely.
  let presenceEndpoint = null;
  const loadPresenceEndpoint = async () => {
    presenceEndpoint = await byteSubscriptionEndpoint();
  };
  const sendPresence = (state) => {
    try {
      const csrf =
        document
          .querySelector('meta[name="csrf-token"]')
          ?.getAttribute("content") || "";
      fetch("/byte/presence", {
        method: "POST",
        credentials: "same-origin",
        headers: {
          "Content-Type": "application/json",
          Accept: "application/json",
          "X-CSRF-Token": csrf,
        },
        body: JSON.stringify({ state: state, endpoint: presenceEndpoint }),
        keepalive: true,
      }).catch(() => {});
    } catch (_) {}
  };
  const startPresence = () => {
    loadPresenceEndpoint().then(() => sendPresence("visible"));
    if (presenceInterval) clearInterval(presenceInterval);
    // 15s < 30s TTL server-side, so a missed heartbeat still falls off
    // within one interval and pushes resume when we're actually gone.
    presenceInterval = setInterval(() => sendPresence("visible"), 15_000);
  };
  const stopPresence = () => {
    sendPresence("hidden");
    if (presenceInterval) {
      clearInterval(presenceInterval);
      presenceInterval = 0;
    }
  };
  if (document.visibilityState === "visible") startPresence();
  window.addEventListener("pagehide", stopPresence);

  document.addEventListener("visibilitychange", async () => {
    if (document.visibilityState === "visible") {
      startPresence();
      scheduleDrain();
      refetchHistory();
      requestShellRefresh();
      checkForServiceWorkerUpdate();
      // Re-validate push on every return-to-app (mirrors whisper.js): recovers
      // a subscription iOS silently dropped while backgrounded, re-syncs the
      // (possibly rotated) endpoint to the server, and repaints the bell from
      // the true current state instead of trusting the stale load-time paint.
      const notifyState = await ensureByteServiceWorker();
      refreshNotifyBtn(notifyState);
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
        try {
          await reg.update();
        } catch (_) {}

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

  // How long the arrows turn before the button admits nothing happened.
  // `location.replace` does not reject when there's no connection — it just
  // never navigates — so on a dead link this timer is the only thing that ends
  // the spin. Generous, because a slow reload that DOES land shouldn't get
  // called a failure on the way.
  const RELOAD_STALL_MS = 12_000;

  let reloadTimer = null;

  function setReloading(on) {
    if (!reloadBtn) return;
    reloadBtn.classList.toggle("is-reloading", on);
    reloadBtn.setAttribute("aria-busy", on ? "true" : "false");
  }

  function reloadStalled() {
    reloadTimer = null;
    setReloading(false);
    if (!reloadBtn) return;

    // Put back whatever setUpdateAvailable last wrote rather than assuming
    // "Reload" — an update may well still be queued behind this.
    const title = reloadBtn.getAttribute("title");
    reloadBtn.classList.add("is-stalled");
    reloadBtn.setAttribute(
      "title",
      "Reload didn't go through - tap to try again",
    );
    setTimeout(() => {
      reloadBtn.classList.remove("is-stalled");
      reloadBtn.setAttribute("title", title);
    }, 3000);
  }

  // Deliberately nothing awaits this before the user can carry on: the spin is
  // the whole feedback, and the reload runs exactly as it did before.
  async function onReloadTap() {
    if (reloadTimer) return; // already going — a second tap changes nothing

    setReloading(true);
    reloadTimer = setTimeout(reloadStalled, RELOAD_STALL_MS);
    try {
      await hardReload();
      // No clearTimeout on the happy path: the navigation is in flight and the
      // timer dies with the document. Stopping the spin here would blink the
      // icon back to rest mid-swap.
    } catch (_) {
      clearTimeout(reloadTimer);
      reloadStalled();
    }
  }

  reloadBtn?.addEventListener("click", onReloadTap);

  // bfcache restores the DOM exactly as it was, spinner included, on a page
  // that is very much not reloading any more.
  window.addEventListener("pageshow", (e) => {
    if (!e.persisted) return;

    clearTimeout(reloadTimer);
    reloadTimer = null;
    setReloading(false);
    reloadBtn?.classList.remove("is-stalled");
  });

  // Populate the "sw" version footer in the drawer. Asks the active
  // service worker for its version; the SW replies via a broadcast
  // (kind: "sw_version") which lands in the onShellSync handler below.
  async function requestSwVersion() {
    try {
      const reg = await navigator.serviceWorker?.getRegistration("/");
      const sw = reg?.active;
      const el = document.querySelector("[data-byte-version-sw]");
      if (!sw) {
        if (el) el.textContent = "(none)";
        return;
      }
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
      // The kiosk takes it immediately instead. Its header is hidden, so the
      // "!" badge has nowhere to appear and there's no reload button to press
      // — a wall tablet nobody navigates would otherwise sit on the shell it
      // booted with forever. Anything unanswered on screen comes back: that's
      // what buddyKiosk.sync restores after the load.
      if (isKiosk) hardReload();
      else setUpdateAvailable(true);
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
  const initialNotifyState = await ensureByteServiceWorker();

  // ---------- notifications button ----------

  async function refreshNotifyBtn(knownState) {
    if (!notifyBtn) return;
    const state = knownState || (await checkByteNotificationStatus());
    notifyBtn.classList.remove("subscribed", "denied", "unsupported");
    if (state === "subscribed") notifyBtn.classList.add("subscribed");
    if (state === "denied") notifyBtn.classList.add("denied");
    if (state === "unsupported") notifyBtn.classList.add("unsupported");
    const title =
      {
        subscribed: "Notifications on — tap to disable",
        unsubscribed: "Notifications off — tap to enable",
        denied: "Blocked by browser — enable in site settings",
        unsupported: "Notifications unavailable in this browser",
      }[state] || "Toggle notifications";
    notifyBtn.setAttribute("title", title);
    notifyBtn.setAttribute("aria-label", title);
  }

  function surfaceLocal(body, kind = "system") {
    const stub = {
      id: `local-${Date.now()}-${Math.random().toString(36).slice(2)}`,
      conversation_id: currentConversationId,
      direction: "inbound",
      state: "delivered",
      body: body,
      created_at: new Date().toISOString(),
      metadata: { kind: kind, local: true },
      attachments: [],
    };
    upsertMessage(stub);
    if (atBottom) scrollToBottom("smooth");
  }

  notifyBtn?.addEventListener("click", async () => {
    const state = await checkByteNotificationStatus();
    if (state === "unsupported") {
      surfaceLocal(
        "**Notifications unavailable** — this browser doesn't support Web Push.",
      );
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
        surfaceLocal("Notifications **enabled**.");
      } else {
        const reason = (result && result.error) || "unknown error";
        surfaceLocal(`**Couldn't enable notifications:** \`${reason}\``);
      }
    }
    refreshNotifyBtn();
  });

  refreshNotifyBtn(initialNotifyState);

  scheduleDrain();

  setTimeout(() => {
    if (syncBadge?.dataset.state === "syncing") setSyncBadge("", "");
  }, 4000);
});
