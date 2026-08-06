// Conversation list + drawer UI + new/rename/archive/adopt-session flows.
//
// The API surface for index.js is intentionally narrow: initialise once
// with the config + callbacks, then react to a single `onSwitch(convId)`
// stream. All server calls, DOM management, and modal handling happen
// inside — index.js doesn't need to know about drawer state.

const CONVOS_KEY = "byte:conversations:v1";
const CURRENT_KEY = "byte:current_conversation:v1";

function csrfMetaToken() {
  return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
}

// What to call a thread in the list, the header, and the menu. `name` is
// already the server's resolved display name; `buddy_name` is the fallback for
// a Buddy thread that was never given one, so an unnamed Suki thread reads
// "Suki".
//
// The last resort walks to the account's own default pet rather than a
// literal — naming somebody else's companion is worse than being vague.
function convoLabel(convo) {
  if (convo?.name) return convo.name;
  if (convo?.buddy_name) return convo.buddy_name;

  const theme = document.querySelector(".byte-app")?.dataset.defaultBuddyTheme;
  return buddyThemes()[theme]?.name || "Conversation";
}

// Modes that run on the owner's Mac and therefore have a working directory.
// Mirrors ByteConversation::MAC_MODES.
const MAC_MODES = ["claude", "bash", "cursor"];

// The pet table the server rendered onto `.byte-app` (ByteHelper#buddy_themes_json).
// Read here as well as in index.js — same single attribute, so there's still one
// source of truth; the drawer just needs it to show which pet a row belongs to.
let themeTable = null;

function buddyThemes() {
  if (themeTable) return themeTable;
  try {
    themeTable = JSON.parse(
      document.querySelector(".byte-app")?.dataset.buddyThemes || "{}",
    );
  } catch (e) {
    themeTable = {};
  }
  return themeTable;
}

// A Buddy row leads with its pet's face rather than the mode chip: every one of
// them says "buddy", so the chip carries no information while the face is the
// whole question ("which of these is Suki?").
function convoBadge(convo) {
  const chrome = convo?.mode === "buddy" && buddyThemes()[convo.buddy_theme];
  if (!chrome) {
    return `<span class="byte-convo-mode" data-mode="${escapeAttr(convo.mode)}">${escapeAttr(convo.mode)}</span>`;
  }

  return `<img class="byte-convo-avatar" src="${escapeAttr(chrome.avatar)}" alt="${escapeAttr(chrome.name)}" loading="lazy">`;
}

// Shared fetch helper. Keeps CSRF/credentials boilerplate out of every
// call site. `body` is JSON-stringified when present.
async function apiCall(url, method, body) {
  const options = {
    method,
    credentials: "same-origin",
    headers: {
      Accept:         "application/json",
      "X-CSRF-Token": csrfMetaToken(),
    },
  };
  if (body != null) {
    options.headers["Content-Type"] = "application/json";
    options.body = JSON.stringify(body);
  }
  const res = await fetch(url, options);
  if (!res.ok) throw new Error(`http_${res.status}`);
  if (res.status === 204) return null;
  return res.json();
}

function loadCurrentId() {
  try { return localStorage.getItem(CURRENT_KEY); }
  catch (e) { return null; }
}

function saveCurrentId(id) {
  try { localStorage.setItem(CURRENT_KEY, String(id)); }
  catch (e) {}
}

function loadCachedList() {
  try {
    const raw = JSON.parse(localStorage.getItem(CONVOS_KEY) || "[]");
    return Array.isArray(raw) ? raw : [];
  } catch (e) { return []; }
}

function saveCachedList(list) {
  try { localStorage.setItem(CONVOS_KEY, JSON.stringify(list)); }
  catch (e) {}
}

export class ConversationManager {
  constructor({
    conversationsUrl,
    claudeSessionsUrl,
    initialConversationId,
    pinnedConversationId,
    initialConversations,
    onSwitch,
    prefillComposer,
    sendCommand,
    unreadFor,
  }) {
    this.conversationsUrl   = conversationsUrl;
    this.claudeSessionsUrl  = claudeSessionsUrl;
    this.onSwitch           = onSwitch;
    // Prefill hook so drawer menu actions like `/rename ` can drop a
    // partial command into the composer for the user to complete.
    this.prefillComposer    = prefillComposer || (() => {});
    // Programmatic send — auto-fires slash commands like `/adopt <name>`
    // straight at a target conversation so the user doesn't have to
    // pick, then confirm, then hit send. Optimistic by design.
    this.sendCommand        = sendCommand || (() => {});
    // Read-only accessor for the current unread count per conversation
    // (Map-backed in index.js). Rendered as a badge on each row.
    this.unreadFor          = unreadFor || (() => 0);
    this.conversations      = initialConversations && initialConversations.length
      ? initialConversations
      : loadCachedList();
    // Resolve initial id, most-specific first. A pinned id comes from an
    // explicit `?conversation_id=` — a request rather than a guess, so it beats
    // whatever this browser happened to have open last; that's what makes a
    // link to a thread land on that thread. Otherwise the last-viewed one from
    // localStorage, then the server's pick, then anything at all.
    const pinned = this.conversations.find((c) => c.id === pinnedConversationId);
    const preferred = String(loadCurrentId() || "");
    const validPreferred = this.conversations.find((c) => String(c.id) === preferred);
    this.currentId =
      pinned?.id ??
      (validPreferred ? Number(preferred) : null) ??
      initialConversationId ??
      this.conversations[0]?.id ??
      null;

    this.menuTargetId = null;
    this.bindDom();
    this.render();
    saveCurrentId(this.currentId);
    saveCachedList(this.conversations);

    // Refresh from server in the background so a stale localStorage cache
    // doesn't linger — never blocks first paint.
    this.refresh().catch(() => {});
  }

  bindDom() {
    this.drawer     = document.querySelector("[data-byte-drawer]");
    this.backdrop   = document.querySelector("[data-byte-drawer-backdrop]");
    this.list       = document.querySelector("[data-byte-convo-list]");
    this.nameEl     = document.querySelector("[data-byte-convo-name]");
    this.modeEl     = document.querySelector("[data-byte-mode-chip]");
    this.composer      = document.querySelector("[data-byte-composer]");
    this.jarvisImg     = document.querySelector("[data-byte-composer-avatar-jarvis]");
    this.pwdBar        = document.querySelector("[data-byte-pwd]");
    this.pwdPath       = document.querySelector("[data-byte-pwd-path]");
    this.pwdMode       = document.querySelector("[data-byte-pwd-mode]");
    // Only Jarvis needs a runtime image src; Claude and Bash are set
    // statically by the template (Byte image + `$` text respectively).
    if (this.jarvisImg && !this.jarvisImg.getAttribute("src")) {
      this.jarvisImg.setAttribute("src", "/favicon/apple-touch-icon.png");
    }
    this.newModal   = document.querySelector("[data-byte-new-modal]");
    this.newForm    = document.querySelector("[data-byte-new-form]");
    this.menuModal  = document.querySelector("[data-byte-convo-menu]");
    this.menuTitle  = document.querySelector("[data-byte-menu-title]");
    this.adoptModal = document.querySelector("[data-byte-adopt-modal]");
    this.adoptList  = document.querySelector("[data-byte-adopt-list]");
    this.adoptHint  = document.querySelector("[data-byte-adopt-hint]");

    document.querySelector("[data-byte-drawer-toggle]")?.addEventListener("click", () => this.openDrawer());
    document.querySelector("[data-byte-drawer-close]")?.addEventListener("click",  () => this.closeDrawer());
    this.backdrop?.addEventListener("click", () => this.closeDrawer());
    document.querySelector("[data-byte-new-convo]")?.addEventListener("click", () => this.openNewModal());
    document.querySelector("[data-byte-new-cancel]")?.addEventListener("click", () => this.newModal?.close());
    this.newForm?.addEventListener("submit", (e) => this.handleCreateSubmit(e));
    document.querySelector("[data-byte-new-mode]")
      ?.addEventListener("change", () => this.syncNewBuddyRow());

    document.querySelector("[data-byte-menu-close]")?.addEventListener("click", () => this.menuModal?.close());
    this.pwdMode?.addEventListener("click", () => this.togglePermissionMode());
    document.querySelector("[data-byte-menu-rename]")?.addEventListener("click", () => this.handleRename());
    document.querySelector("[data-byte-menu-archive]")?.addEventListener("click", () => this.handleArchive());
    document.querySelector("[data-byte-menu-adopt]")?.addEventListener("click", () => this.handleAdoptOpen());
    document.querySelector("[data-byte-adopt-close]")?.addEventListener("click", () => this.adoptModal?.close());
  }

  currentConversation() {
    return this.conversations.find((c) => c.id === this.currentId) || null;
  }

  // ---------- server sync ----------

  async refresh() {
    try {
      const data = await apiCall(this.conversationsUrl, "GET");
      if (data && Array.isArray(data.conversations)) {
        this.conversations = data.conversations;
        saveCachedList(this.conversations);
        // If our current id disappeared server-side (archived elsewhere),
        // fall back to the server-declared default.
        if (!this.currentConversation() && data.default_id) {
          this.switchTo(data.default_id);
        }
        this.render();
      }
    } catch (e) {}
  }

  async createConversation({ name, mode, buddyTheme, cwd }) {
    const created = await apiCall(this.conversationsUrl, "POST", {
      name,
      mode,
      buddy_theme: mode === "buddy" ? buddyTheme : null,
      // Only the Mac modes have a working directory; the server ignores it for
      // the others, and sending it anyway would just be noise on the wire.
      cwd: MAC_MODES.includes(mode) ? cwd : null,
    });
    if (!created || !created.id) return null;
    // Upsert into local cache and switch to it.
    this.conversations = [created, ...this.conversations.filter((c) => c.id !== created.id)];
    saveCachedList(this.conversations);
    this.switchTo(created.id);
    this.render();
    return created;
  }

  async updateConversation(id, attrs) {
    const url = this.conversationsUrl.replace(/\/?$/, "") + "/" + id;
    const updated = await apiCall(url, "PATCH", attrs);
    if (!updated) return null;
    const idx = this.conversations.findIndex((c) => c.id === id);
    if (idx >= 0) this.conversations[idx] = updated;
    saveCachedList(this.conversations);
    this.render();
    return updated;
  }

  // Optimistic archive: strip the conversation from the local list + jump
  // to a survivor immediately, then fire the DELETE. If the server rejects,
  // put it back and re-render. Matches the "assume it will work" pattern —
  // the drawer feels instant instead of stalling on a network round-trip.
  async archiveConversation(id) {
    const idx = this.conversations.findIndex((c) => c.id === id);
    if (idx < 0) return;
    const removed = this.conversations[idx];
    const wasCurrent = this.currentId === id;

    // Optimistic removal + jump.
    this.conversations = this.conversations.filter((c) => c.id !== id);
    saveCachedList(this.conversations);
    if (wasCurrent) {
      const next = this.conversations[0]?.id;
      if (next) this.switchTo(next);
      else this.render();
    } else {
      this.render();
    }

    // Confirm with the server; roll back on failure so the user doesn't
    // silently think it archived when the API rejected them.
    const url = this.conversationsUrl.replace(/\/?$/, "") + "/" + id;
    try {
      await apiCall(url, "DELETE");
      // If we ended up with an empty list AND we were on the archived
      // conversation, refresh so the server can default us somewhere.
      if (wasCurrent && this.conversations.length === 0) {
        await this.refresh();
      }
    } catch (err) {
      this.conversations.splice(idx, 0, removed);
      saveCachedList(this.conversations);
      if (wasCurrent) this.switchTo(id);
      else this.render();
      alert(`Archive failed: ${err.message || err}`);
    }
  }

  // Server-broadcast conversation-lifecycle event (create/update/archive).
  applyBroadcast(payload) {
    if (!payload) return;
    const convo = payload.conversation;
    if (!convo) return;

    if (payload.event === "archived") {
      this.conversations = this.conversations.filter((c) => c.id !== convo.id);
    } else {
      const idx = this.conversations.findIndex((c) => c.id === convo.id);
      if (idx >= 0) this.conversations[idx] = convo;
      else this.conversations.unshift(convo);
      // Keep sort roughly by last activity (server already does this on
      // fetch — this is a best-effort local reorder for freshness).
      this.conversations.sort((a, b) => {
        const at = a.last_message_at ? Date.parse(a.last_message_at) : 0;
        const bt = b.last_message_at ? Date.parse(b.last_message_at) : 0;
        return bt - at;
      });
    }
    saveCachedList(this.conversations);
    this.render();
  }

  // Bump the local ordering when a new message lands in a conversation so
  // an actively-chatted thread floats to the top without a server round-trip.
  bumpActivity(convId, iso) {
    const idx = this.conversations.findIndex((c) => c.id === convId);
    if (idx < 0) return;
    this.conversations[idx] = { ...this.conversations[idx], last_message_at: iso };
    this.conversations.sort((a, b) => {
      const at = a.last_message_at ? Date.parse(a.last_message_at) : 0;
      const bt = b.last_message_at ? Date.parse(b.last_message_at) : 0;
      return bt - at;
    });
    saveCachedList(this.conversations);
    this.render();
  }

  // ---------- rendering ----------

  render() {
    const convo = this.currentConversation();
    if (this.nameEl && convo) this.nameEl.textContent = convoLabel(convo);
    if (this.modeEl && convo) {
      this.modeEl.textContent = convo.mode;
      this.modeEl.dataset.mode = convo.mode;
    }
    // Top-level active-mode marker so page-wide CSS can gate on it
    // (e.g. hide the pwd/session banner when we're chatting with Buddy).
    const app = document.querySelector(".byte-app");
    if (app && convo) app.dataset.activeMode = convo.mode;
    // Composer mode marker drives colour + chip toggling via CSS
    // ([data-mode="bash"] etc). Set the chip image src for modes that
    // use an image (Jarvis). The Byte avatar to the left never changes.
    if (this.composer && convo) {
      this.composer.dataset.mode = convo.mode;
      if (this.modeImg) {
        const src = this.modeChipSrc[convo.mode];
        if (src) this.modeImg.setAttribute("src", src);
        else this.modeImg.removeAttribute("src");
      }
      // Bash is a shell REPL — kill auto-capitalize/correct/spellcheck so
      // commands, flags, and paths aren't mangled; restore the prose assists
      // for every other mode. (Server-renders the same for the initial mode.)
      const inputEl = this.composer.querySelector("[data-byte-input]");
      if (inputEl) {
        const bash = convo.mode === "bash";
        inputEl.setAttribute("autocapitalize", bash ? "none" : "sentences");
        inputEl.setAttribute("autocorrect", bash ? "off" : "on");
        inputEl.setAttribute("spellcheck", bash ? "false" : "true");
      }
    }
    // Header subtitle: cwd (defaults to Portfolio) + adopted Claude
    // session name (if any). The Mac pushes both into
    // conversation.metadata; when neither is known yet we still show the
    // Portfolio default so the header block never feels empty.
    if (this.pwdBar && this.pwdPath && convo) {
      const cwd = (convo.metadata && convo.metadata.cwd) || "~/code/Portfolio";
      this.pwdPath.textContent = shortHome(cwd);
      this.pwdBar.dataset.visible = "true";

      const sessionWrap = document.querySelector("[data-byte-pwd-session]");
      const sessionName = document.querySelector("[data-byte-pwd-session-name]");
      const name        = convo.metadata && convo.metadata.claude_session_name;
      if (sessionWrap && sessionName) {
        if (name && String(name).trim()) {
          sessionName.textContent = name;
          sessionWrap.hidden = false;
        } else {
          sessionWrap.hidden = true;
        }
      }

      // "watching N" chip when the Mac has active WatchStreamer streams
      // for this conversation. Silent when zero.
      let watchChip = document.querySelector("[data-byte-pwd-watching]");
      if (!watchChip) {
        watchChip = document.createElement("span");
        watchChip.className = "byte-pwd-watching";
        watchChip.setAttribute("data-byte-pwd-watching", "");
        watchChip.hidden = true;
        this.pwdBar.appendChild(watchChip);
      }
      const watching = Number(convo.metadata && convo.metadata.watching_count) || 0;
      if (watching > 0) {
        watchChip.textContent = `👁 watching ${watching}`;
        watchChip.hidden = false;
      } else {
        watchChip.hidden = true;
      }

      // Permission-mode chip — only meaningful for Claude mode (the one whose
      // tool calls route through the Mac's approval hook).
      if (this.pwdMode) {
        const isClaude = convo.mode === "claude";
        this.pwdMode.hidden = !isClaude;
        if (isClaude) this.setPwdModeUI(this.permissionModeFor(convo));
      }
    }

    if (!this.list) return;
    this.list.innerHTML = "";
    this.conversations.forEach((c) => this.list.appendChild(this.renderConvoRow(c)));
  }

  permissionModeFor(convo) {
    return convo && convo.metadata && convo.metadata.permission_mode === "auto" ? "auto" : "ask";
  }

  setPwdModeUI(mode, pending = false) {
    if (!this.pwdMode) return;
    this.pwdMode.dataset.mode = mode;
    this.pwdMode.dataset.pending = pending ? "true" : "false";
    const label = this.pwdMode.querySelector("[data-byte-pwd-mode-label]");
    if (label) label.textContent = mode;
  }

  // Flip the current Claude conversation between "ask" (prompt per tool) and
  // "auto" (Mac approves tool calls without prompting). Shows the target state
  // with a pending hint until the server confirms, then rolls back on error.
  async togglePermissionMode() {
    const convo = this.conversations.find((c) => c.id === this.currentId);
    if (!convo || convo.mode !== "claude") return;

    const prev = this.permissionModeFor(convo);
    const next = prev === "auto" ? "ask" : "auto";
    this.setPwdModeUI(next, true);
    try {
      await apiCall(`/byte/conversations/${convo.id}`, "PATCH", { metadata: { permission_mode: next } });
      convo.metadata = Object.assign({}, convo.metadata, { permission_mode: next });
      saveCachedList(this.conversations);
      this.setPwdModeUI(next, false);
    } catch (e) {
      this.setPwdModeUI(prev, false); // server rejected — revert the chip
    }
  }

  renderConvoRow(convo) {
    const li = document.createElement("li");
    li.className = "byte-convo-row" + (convo.id === this.currentId ? " active" : "");
    li.dataset.conversationId = String(convo.id);

    const unread = this.unreadFor(convo.id);
    const unreadHtml = unread > 0
      ? `<span class="byte-convo-unread">${unread > 99 ? "99+" : unread}</span>`
      : "";

    const pick = document.createElement("button");
    pick.type = "button";
    pick.className = "byte-convo-pick";
    pick.innerHTML = `
      ${convoBadge(convo)}
      <span class="byte-convo-name">${escapeHtml(convoLabel(convo))}</span>
      <span class="byte-convo-time">${relativeTime(convo.last_message_at)}${unreadHtml}</span>
    `;
    pick.addEventListener("click", () => {
      this.switchTo(convo.id);
      this.closeDrawer();
    });

    const menu = document.createElement("button");
    menu.type = "button";
    menu.className = "byte-convo-menu-btn";
    menu.setAttribute("aria-label", "Conversation options");
    menu.textContent = "⋯";
    menu.addEventListener("click", (e) => {
      e.stopPropagation();
      this.openMenu(convo);
    });

    li.appendChild(pick);
    li.appendChild(menu);
    return li;
  }

  // ---------- drawer / modal ----------

  openDrawer() {
    if (!this.drawer) return;
    this.drawer.classList.add("open");
    this.drawer.setAttribute("aria-hidden", "false");
    this.backdrop?.classList.add("open");
    this.backdrop?.setAttribute("aria-hidden", "false");
  }
  closeDrawer() {
    if (!this.drawer) return;
    this.drawer.classList.remove("open");
    this.drawer.setAttribute("aria-hidden", "true");
    this.backdrop?.classList.remove("open");
    this.backdrop?.setAttribute("aria-hidden", "true");
  }

  openNewModal() {
    if (!this.newModal) return;
    this.newForm?.reset();
    // `reset()` restores the markup's selected mode, so re-derive from that
    // rather than assuming the row starts hidden.
    this.syncNewBuddyRow();
    this.loadWorkspaces();
    if (typeof this.newModal.showModal === "function") this.newModal.showModal();
    else this.newModal.setAttribute("open", "");
  }

  // Only a Buddy thread wears a pet, so the picker follows the mode; only a Mac
  // thread has a working directory, so the directory row follows it the other
  // way. For anyone but the owner the mode input is a hidden `buddy`, which
  // means this leaves the pet row visible and the directory row absent.
  syncNewBuddyRow() {
    const mode = document.querySelector("[data-byte-new-mode]")?.value || "claude";
    const buddyRow = document.querySelector("[data-byte-new-buddy-row]");
    if (buddyRow) buddyRow.hidden = mode !== "buddy";

    const cwdRow = document.querySelector("[data-byte-new-cwd-row]");
    if (cwdRow) cwdRow.hidden = !MAC_MODES.includes(mode);
  }

  // The directory list comes from the server's cache of what the Mac last
  // reported, so this resolves whether or not the Mac is awake. Failure is
  // silent on purpose: the field is free text, and an empty datalist costs
  // nothing but typing the path out.
  async loadWorkspaces() {
    const list = document.querySelector("[data-byte-workspace-list]");
    if (!list || list.dataset.loaded === "1") return;

    try {
      const data = await apiCall("/byte/workspaces?limit=100", "GET");
      list.innerHTML = (data?.paths || [])
        .map((p) => `<option value="${escapeAttr(p)}"></option>`)
        .join("");
      list.dataset.loaded = "1";
    } catch (e) {}
  }

  async handleCreateSubmit(e) {
    e.preventDefault();
    const fd = new FormData(this.newForm);
    const name = (fd.get("name") || "").toString().trim();
    const mode = (fd.get("mode") || "buddy").toString();
    const buddyTheme = (fd.get("buddy_theme") || "").toString();
    const cwd = (fd.get("cwd") || "").toString().trim();
    try {
      await this.createConversation({ name, mode, buddyTheme, cwd });
      this.newModal?.close();
      this.closeDrawer();
    } catch (err) {
      alert(`Couldn't create conversation: ${err.message}`);
    }
  }

  openMenu(convo) {
    this.menuTargetId = convo.id;
    if (this.menuTitle) this.menuTitle.textContent = convoLabel(convo);
    // Adopt only makes sense for Claude-mode conversations.
    const adoptBtn = document.querySelector("[data-byte-menu-adopt]");
    if (adoptBtn) adoptBtn.style.display = convo.mode === "claude" ? "" : "none";
    if (typeof this.menuModal.showModal === "function") this.menuModal.showModal();
    else this.menuModal.setAttribute("open", "");
  }

  // Menu actions no longer use window.prompt/confirm. Every mutation is a
  // slash command — tapping a menu row switches to the target conversation
  // (so the command lands on the right thread), closes the drawer/menu,
  // and drops the pre-typed command into the composer for the user to
  // edit or submit. Rename waits for their new-name text; archive is
  // ready-to-send.
  handleRename() {
    if (this.menuTargetId == null) return;
    const target = this.conversations.find((c) => c.id === this.menuTargetId);
    if (!target) return;
    this.menuModal?.close();
    this.closeDrawer();
    this.switchTo(target.id);
    this.prefillComposer("/rename ", { focus: true });
  }

  handleArchive() {
    if (this.menuTargetId == null) return;
    const targetId = this.menuTargetId;
    this.menuModal?.close();
    // Fire-and-forget — archiveConversation is optimistic (list update
    // + switch happen before the API call resolves), so the drawer
    // feels instant. Don't close the drawer: the user tapped a menu
    // in the drawer; showing the row disappear is the visual receipt.
    this.archiveConversation(targetId);
  }

  // Adopt opens a compact chooser modal (read-only from Mac's session
  // dir). Tapping a row prefills the composer with `/adopt <name>` so the
  // command shows up in the thread as a real bubble — no silent mutation.
  async handleAdoptOpen() {
    this.menuModal?.close();
    if (!this.adoptModal || !this.claudeSessionsUrl) return;
    const targetId = this.menuTargetId;
    if (this.adoptList) this.adoptList.innerHTML = "";
    if (this.adoptHint) this.adoptHint.textContent = "Loading sessions from your Mac…";
    if (typeof this.adoptModal.showModal === "function") this.adoptModal.showModal();
    else this.adoptModal.setAttribute("open", "");

    const url = `${this.claudeSessionsUrl}?conversation_id=${targetId}`;
    try {
      const data = await apiCall(url, "GET");
      const sessions = Array.isArray(data?.sessions) ? data.sessions : [];
      if (!sessions.length) {
        if (this.adoptHint) {
          this.adoptHint.textContent = "No Claude sessions found for this conversation's cwd.";
        }
        return;
      }
      if (this.adoptHint) {
        this.adoptHint.textContent = "Pick a session — I'll prefill `/adopt <name>` so you can send it.";
      }
      sessions.forEach((s) => {
        const li = document.createElement("li");
        li.className = "byte-adopt-row";
        const displayName = s.name || s.id.slice(0, 8) + "…";
        li.innerHTML = `
          <div class="byte-adopt-name">${escapeHtml(displayName)}</div>
          <div class="byte-adopt-meta">${relativeTime(s.mtime)} · ${escapeHtml(s.id.slice(0, 8))}</div>
          <div class="byte-adopt-preview">${escapeHtml(truncate(s.preview || "", 120))}</div>
        `;
        li.addEventListener("click", () => {
          this.adoptModal?.close();
          this.closeDrawer();
          this.switchTo(targetId);
          // Fall back to id prefix if the session has no user-friendly name.
          const arg = s.name && s.name.trim() ? s.name : s.id.slice(0, 8);
          // Auto-send. `/adopt <name>` posts as a real bubble in the
          // thread (so there's a receipt), and the Mac's switch_session
          // will follow up with a confirmation + last-context bubble.
          this.sendCommand(targetId, `/adopt ${arg}`);
        });
        this.adoptList?.appendChild(li);
      });
    } catch (e) {
      if (this.adoptHint) {
        this.adoptHint.textContent = "Couldn't reach your Mac. Check ByteLocal.ping.";
      }
    }
  }

  // ---------- switch ----------

  switchTo(id) {
    if (id == null) return;
    if (id === this.currentId) return;
    this.currentId = Number(id);
    saveCurrentId(this.currentId);
    this.render();
    this.onSwitch?.(this.currentId);
  }
}

// ---------- helpers ----------

function escapeHtml(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function escapeAttr(s) { return escapeHtml(s).replace(/"/g, "&quot;"); }

function truncate(s, n) {
  const str = String(s ?? "");
  return str.length > n ? str.slice(0, n) + "…" : str;
}

// Absolute path → `~/…` when it starts with the current user's home.
// Best-effort — the browser doesn't have HOME, so we assume `/Users/<X>`.
function shortHome(path) {
  if (!path) return "";
  const m = path.match(/^\/Users\/[^\/]+/);
  return m ? path.replace(m[0], "~") : path;
}

// "just now", "3m", "2h", "5d". Nothing longer — the drawer sorts by
// activity so anything older than a week is rare and imprecise-is-fine.
function relativeTime(iso) {
  if (!iso) return "";
  const t = Date.parse(iso);
  if (!t) return "";
  const secs = Math.max(0, Math.floor((Date.now() - t) / 1000));
  if (secs < 60)    return `${secs}s`;
  if (secs < 3600)  return `${Math.floor(secs / 60)}m`;
  if (secs < 86400) return `${Math.floor(secs / 3600)}h`;
  return `${Math.floor(secs / 86400)}d`;
}
