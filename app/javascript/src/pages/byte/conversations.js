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
    initialConversations,
    onSwitch,
    prefillComposer,
    unreadFor,
  }) {
    this.conversationsUrl   = conversationsUrl;
    this.claudeSessionsUrl  = claudeSessionsUrl;
    this.onSwitch           = onSwitch;
    // Prefill hook so drawer menu actions can drop `/rename `, `/adopt `,
    // etc. straight into the composer with the caret positioned at the
    // end — replaces window.prompt/confirm entirely.
    this.prefillComposer    = prefillComposer || (() => {});
    // Read-only accessor for the current unread count per conversation
    // (Map-backed in index.js). Rendered as a badge on each row.
    this.unreadFor          = unreadFor || (() => 0);
    this.conversations      = initialConversations && initialConversations.length
      ? initialConversations
      : loadCachedList();
    // Resolve initial id: server bootstrap wins, then localStorage, then
    // fall back to the first known conversation.
    const preferred = String(loadCurrentId() || "");
    const validPreferred = this.conversations.find((c) => String(c.id) === preferred);
    this.currentId = validPreferred
      ? Number(preferred)
      : (initialConversationId ?? this.conversations[0]?.id ?? null);

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
    this.composer   = document.querySelector("[data-byte-composer]");
    this.modeImg    = document.querySelector("[data-byte-composer-mode-img]");
    this.pwdBar     = document.querySelector("[data-byte-pwd]");
    this.pwdPath    = document.querySelector("[data-byte-pwd-path]");
    // Mode-indicator chip src per mode. Bash uses a text glyph via CSS
    // (no img). Jarvis falls back to the site favicon — the closest
    // Ardesian brand mark we have; swap once a dedicated logo lands.
    this.modeChipSrc = {
      jarvis: "/favicon/apple-touch-icon.png",
    };
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

    document.querySelector("[data-byte-menu-close]")?.addEventListener("click", () => this.menuModal?.close());
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

  async createConversation({ name, mode }) {
    const created = await apiCall(this.conversationsUrl, "POST", { name, mode });
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

  async archiveConversation(id) {
    const url = this.conversationsUrl.replace(/\/?$/, "") + "/" + id;
    await apiCall(url, "DELETE");
    this.conversations = this.conversations.filter((c) => c.id !== id);
    saveCachedList(this.conversations);
    // If we archived the current, jump to the newest survivor (or trigger
    // refresh which will land on the server default).
    if (this.currentId === id) {
      const next = this.conversations[0]?.id;
      if (next) this.switchTo(next);
      else await this.refresh();
    } else {
      this.render();
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
    if (this.nameEl && convo) this.nameEl.textContent = convo.name || "Byte";
    if (this.modeEl && convo) {
      this.modeEl.textContent = convo.mode;
      this.modeEl.dataset.mode = convo.mode;
    }
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
    }
    // Pwd bar shows the effective working directory for the current
    // conversation. Hidden entirely when unknown so we don't display a
    // stale/generic path.
    if (this.pwdBar && this.pwdPath && convo) {
      const cwd = convo.metadata && convo.metadata.cwd;
      if (cwd) {
        this.pwdPath.textContent = shortHome(cwd);
        this.pwdBar.dataset.visible = "true";
      } else {
        this.pwdBar.dataset.visible = "false";
      }
    }

    if (!this.list) return;
    this.list.innerHTML = "";
    this.conversations.forEach((c) => this.list.appendChild(this.renderConvoRow(c)));
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
      <span class="byte-convo-mode" data-mode="${escapeAttr(convo.mode)}">${escapeAttr(convo.mode)}</span>
      <span class="byte-convo-name">${escapeHtml(convo.name || "Byte")}</span>
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
    if (typeof this.newModal.showModal === "function") this.newModal.showModal();
    else this.newModal.setAttribute("open", "");
  }

  async handleCreateSubmit(e) {
    e.preventDefault();
    const fd = new FormData(this.newForm);
    const name = (fd.get("name") || "").toString().trim();
    const mode = (fd.get("mode") || "claude").toString();
    try {
      await this.createConversation({ name, mode });
      this.newModal?.close();
      this.closeDrawer();
    } catch (err) {
      alert(`Couldn't create conversation: ${err.message}`);
    }
  }

  openMenu(convo) {
    this.menuTargetId = convo.id;
    if (this.menuTitle) this.menuTitle.textContent = convo.name || "Byte";
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
    this.menuModal?.close();
    this.closeDrawer();
    this.switchTo(this.menuTargetId);
    this.prefillComposer("/archive", { focus: true, selectAll: false });
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
          this.prefillComposer(`/adopt ${arg}`, { focus: true });
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
