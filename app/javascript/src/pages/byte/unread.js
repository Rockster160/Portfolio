// Unread tracking for conversations the user isn't looking at, plus the
// in-app notice that one arrived.
//
// The counter used to be a plain `Map<convId, number>` incremented once per
// BROADCAST, which is not once per message. A Claude turn re-broadcasts the
// same row every time its text grows (RailsClient.update_message on a throttle,
// state "streaming"), so one reply working through a long task pushed the badge
// up by dozens while nothing had actually been said yet. Two things fix it:
// counting message IDS rather than events, and only counting a message once it
// has SETTLED.

// States where the message is done moving. `streaming` / `pending` / `queued`
// are all mid-flight and must never count. `failed` does count — it's terminal
// and it's something the person needs to see.
const SETTLED_STATES = new Set(["delivered", "sent", "failed"]);

// Receipt chips, tapped-action pills and the hidden trigger seeds are not
// things anyone reads. They ride the same broadcast as real messages, and
// they're the other half of why a working Claude session ran the badge up:
// every tool call posts one.
const SILENT_KINDS = new Set(["buddy_activity", "action_chip", "buddy_trigger"]);

export function countsAsUnread(msg) {
  if (!msg || msg.direction !== "inbound") return false;
  if (!SETTLED_STATES.has(String(msg.state))) return false;

  const meta = msg.metadata || {};
  if (meta.hidden === true) return false;
  if (SILENT_KINDS.has(String(meta.kind))) return false;

  return true;
}

// Per-conversation unread, as a server-given BASE plus a set of live ids.
//
// The base is what the server counted from `last_read_at`. It's what makes the
// number survive a reload, and the only thing that can know about messages that
// arrived while the app was closed — those never produce a broadcast, so a
// purely live counter is blind to them and starts every session at zero.
//
// The live half is a SET, not a tally: the same message is broadcast many times
// (it streams, it settles, a late edit re-broadcasts it), and all of those are
// one thing to read.
export class UnreadTracker {
  constructor({ onChange } = {}) {
    this.byConversation = new Map();
    this.base = new Map();
    this.onChange = onChange || (() => {});
  }

  // Take the server's count for a conversation.
  //
  // Skipped when live ids are already held for that thread: the server's number
  // was computed before those arrived, so adopting it would drop them. Letting
  // the base stand and keeping the live set is right either way, because the
  // next read clears both.
  seed(convId, count) {
    if (convId == null) return;
    if ((this.byConversation.get(convId)?.size || 0) > 0) return;

    const n = Math.max(0, Number(count) || 0);
    if (this.base.get(convId) === n) return;

    this.base.set(convId, n);
    this.onChange();
  }

  seedAll(conversations, { except } = {}) {
    (conversations || []).forEach((c) => {
      if (c.id === except) return;
      this.seed(c.id, c.unread_count);
    });
  }

  // Returns true only when this is genuinely new — the caller uses that to
  // decide whether to raise a notice, so a re-broadcast stays silent.
  add(convId, msg) {
    if (convId == null || !countsAsUnread(msg) || msg.id == null) return false;

    let ids = this.byConversation.get(convId);
    if (!ids) {
      ids = new Set();
      this.byConversation.set(convId, ids);
    }
    if (ids.has(msg.id)) return false;

    ids.add(msg.id);
    this.onChange();
    return true;
  }

  countFor(convId) {
    return (this.base.get(convId) || 0) + (this.byConversation.get(convId)?.size || 0);
  }

  total() {
    let n = 0;
    const ids = new Set([...this.base.keys(), ...this.byConversation.keys()]);
    ids.forEach((convId) => {
      n += this.countFor(convId);
    });
    return n;
  }

  conversationCount() {
    let n = 0;
    const ids = new Set([...this.base.keys(), ...this.byConversation.keys()]);
    ids.forEach((convId) => {
      if (this.countFor(convId) > 0) n += 1;
    });
    return n;
  }

  // Reading a thread clears BOTH halves — the server's marker moves at the same
  // moment (POST .../read), so leaving the base behind would double-count
  // everything in it the next time the list is seeded.
  clear(convId) {
    const had = this.countFor(convId) > 0;
    this.byConversation.delete(convId);
    this.base.delete(convId);
    if (had) this.onChange();
  }
}

// One line of plain text for the notice.
//
// Mirrors ByteNotifier#clean_body on the server, which does the same job for
// the push tray — a shell bubble carries ANSI-styled `<span>`s and Buddy writes
// markdown, and both look like garbage rendered as-is in a small strip.
const PREVIEW_LIMIT = 90;

export function previewOf(msg) {
  const text = String(msg?.body || "")
    .replace(/```[a-z]*\n?/gi, "")
    .replace(/```/g, "")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/\*\*([^*]+)\*\*/g, "$1")
    .replace(/<[^>]+>/g, "")
    .replace(/^>\s?/gm, "")
    .replace(/\[\[[^\]]*\]\]/g, "")
    .replace(/\s+/g, " ")
    .trim();

  if (!text) return "(attachment)";
  return text.length > PREVIEW_LIMIT ? `${text.slice(0, PREVIEW_LIMIT - 1)}…` : text;
}

// The badge on the drawer toggle. Its whole job is "there is something over
// here you haven't seen", so it's the total across every conversation the
// person isn't currently in.
export function paintDrawerBadge(el, total) {
  if (!el) return;
  el.textContent = total > 99 ? "99+" : String(total);
  el.hidden = total <= 0;
}

// A message landed in a thread that isn't on screen — or somebody reacted to
// one of yours, which has no other announcement while the app is open.
//
// One notice per message, stacked, never merged. A run of them is a run of real
// events and collapsing them into "3 new messages" would throw away the only
// part worth reading. They sit in a corner and time out on their own — nothing
// here takes the tap target away from what the person was already doing.
const NOTICE_TTL_MS = 8000;
const MAX_VISIBLE = 4;

export function initUnreadNotices({ root, onOpen }) {
  if (!root) return { notify: () => {} };

  function dismiss(node) {
    if (!node.isConnected) return;
    node.classList.add("is-leaving");
    node.addEventListener("transitionend", () => node.remove(), { once: true });
    // Belt and braces: if the element never transitions (reduced motion, or a
    // display change mid-flight) it would otherwise sit there forever.
    setTimeout(() => node.remove(), 400);
  }

  // `messageId` makes the notice point at one message rather than just its
  // thread — a reaction notice names a bubble somewhere up the scrollback, and
  // opening the conversation at the bottom would leave the person hunting for
  // it. `accessory` is a caller-built node shown at the end (the reaction
  // itself); a node rather than a value, so this stays ignorant of how an icon
  // reference becomes pixels.
  function notify({ convId, messageId, title, body, icon, accessory }) {
    const node = document.createElement("button");
    node.type = "button";
    node.className = "byte-notice";
    node.dataset.conversationId = String(convId);

    const iconHtml = icon
      ? `<img class="byte-notice-icon" src="${icon}" alt="" />`
      : "";
    node.innerHTML = `
      ${iconHtml}
      <span class="byte-notice-text">
        <span class="byte-notice-title"></span>
        <span class="byte-notice-body"></span>
      </span>
      <span class="byte-notice-accessory" data-notice-accessory hidden></span>
    `;
    node.querySelector(".byte-notice-title").textContent = title || "New message";
    node.querySelector(".byte-notice-body").textContent = body || "";
    if (accessory) {
      const slot = node.querySelector("[data-notice-accessory]");
      slot.hidden = false;
      slot.appendChild(accessory);
    }

    node.addEventListener("click", () => {
      dismiss(node);
      onOpen?.(convId, messageId ?? null);
    });

    root.appendChild(node);
    // Next frame, so the entry transition has a start state to move from.
    requestAnimationFrame(() => node.classList.add("is-in"));

    // Trim the OLDEST once the stack is deep. querySelectorAll is DOM order,
    // which is oldest-first — and the stack renders `column-reverse`, so those
    // are the ones furthest from the header and least likely to be read.
    const all = Array.from(root.querySelectorAll(".byte-notice:not(.is-leaving)"));
    all.slice(0, Math.max(0, all.length - MAX_VISIBLE)).forEach(dismiss);

    setTimeout(() => dismiss(node), NOTICE_TTL_MS);
  }

  return { notify };
}
