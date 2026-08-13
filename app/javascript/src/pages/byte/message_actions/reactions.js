// Tapbacks on a message that passed between two people (Buddy::Reactions).
//
// Two surfaces, one server call: the long-press / right-click menu offers the
// six you last used plus a "+" into the full icon picker, and any reaction
// already on a bubble renders as a pill you can tap to join or take back. Both
// POST to /byte/messages/:id/react, which toggles.
//
// A reaction is an ICON REFERENCE, not an emoji — an emoji character, a `ti-*`
// class, or `hicon:<id>` for one of the household's own uploads. Same three
// shapes the picker hands back everywhere else in the app, so anything you can
// put on a chore you can react with.
//
// Nothing is painted optimistically. The server writes BOTH copies of the relay
// and broadcasts each owner their own, so the repaint is already on its way
// before a local guess would have finished; guessing would only give the two
// copies a moment to disagree. A tapped pill dims until that lands, so the tap
// is visibly doing something without pretending it's done.

import {
  openIconPicker,
  renderIconValue,
  needsIconPool,
  warmIconPool,
} from "../../../icon_picker";

// The six on the picker row: most-recently-used, server-resolved (padded with
// defaults until they've used six of their own). Seeded from the shell and
// replaced by every react response, since reacting is what reorders it.
let recents = [];

export function seedReactionRecents(list) {
  if (Array.isArray(list) && list.length > 0) recents = list.slice();
}

export function reactionRecents() {
  return recents.slice();
}

// Small inline fetch, same as the one in multi_select.js — it lifts `errors`
// off a failure so the caller can say what actually went wrong.
async function apiCall(url, method, body) {
  const csrfMeta = document.querySelector('meta[name="csrf-token"]');
  const csrf = csrfMeta ? csrfMeta.getAttribute("content") : "";
  const res = await fetch(url, {
    method,
    credentials: "same-origin",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
      "X-CSRF-Token": csrf,
    },
    body: body == null ? undefined : JSON.stringify(body),
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = new Error(`HTTP ${res.status}`);
    err.errors = json.errors;
    throw err;
  }
  return json;
}

export async function toggleReaction(messageId, emoji) {
  const json = await apiCall(
    `/byte/messages/${encodeURIComponent(messageId)}/react`,
    "POST",
    { emoji },
  );
  // The server owns the order; taking its answer means the row is right even
  // when the same account reacted from another device.
  if (Array.isArray(json.recents)) recents = json.recents;
  return json;
}

// Open the full pool — emoji, Tabler icons and the household's uploads — and
// react with whatever comes back.
export function pickReaction(messageId, { onNotice } = {}) {
  openIconPicker({
    onPick: (value) => {
      toggleReaction(messageId, value).catch((err) => {
        if (onNotice) {
          onNotice(
            (err.errors && err.errors[0]) ||
              "Couldn't send that reaction — try again.",
          );
        }
      });
    },
  });
}

// A relayed message is the only thing with someone on the other side to see it.
export function reactable(message) {
  return message?.metadata?.kind === "buddy_relay";
}

// One pill per distinct reaction, in the order they were first used, carrying
// who used it. Two people, so a count only ever means "both of us" — but it's
// rendered from the real length rather than assumed.
function group(list, userId) {
  const order = [];
  const byValue = new Map();
  list.forEach((r) => {
    const value = r && r.emoji;
    if (!value) return;
    if (!byValue.has(value)) {
      byValue.set(value, { value, names: [], mine: false });
      order.push(value);
    }
    const g = byValue.get(value);
    g.names.push(r.name || "someone");
    if (userId != null && Number(r.user_id) === Number(userId)) g.mine = true;
  });
  return order.map((v) => byValue.get(v));
}

// Rebuild the pill row from the message. Called on every paint, so it is the
// one place reactions appear and there is nothing to keep in sync.
export function renderReactions(container, message, { userId, onNotice } = {}) {
  if (!container) return;

  const list = Array.isArray(message?.metadata?.reactions)
    ? message.metadata.reactions
    : [];
  if (!reactable(message) || list.length === 0) {
    container.replaceChildren();
    container.hidden = true;
    return;
  }

  const messageId = message.id;
  const groups = group(list, userId);
  container.hidden = false;
  container.replaceChildren();

  groups.forEach((g) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = `byte-msg-reaction${g.mine ? " is-mine" : ""}`;
    btn.dataset.reaction = g.value;
    btn.title = g.names.join(", ");

    const glyph = document.createElement("span");
    glyph.className = "byte-msg-reaction-icon";
    renderIconValue(glyph, g.value);
    btn.appendChild(glyph);

    if (g.names.length > 1) {
      const count = document.createElement("span");
      count.className = "byte-msg-reaction-count";
      count.textContent = String(g.names.length);
      btn.appendChild(count);
    }

    btn.addEventListener("click", async (e) => {
      e.stopPropagation();
      btn.dataset.pending = "true";
      try {
        await toggleReaction(messageId, g.value);
        // The broadcast repaints this whole row a beat later; touching it here
        // would only mean applying the same change twice.
      } catch (err) {
        delete btn.dataset.pending;
        if (onNotice) {
          onNotice(
            (err.errors && err.errors[0]) ||
              "Couldn't send that reaction — tap to try again.",
          );
        }
      }
    });
    container.appendChild(btn);
  });

  // A custom upload can't be drawn until its pool is loaded, and the pool is
  // only fetched on demand. Warm it, then redraw just the pictures.
  if (groups.some((g) => needsIconPool(g.value))) {
    warmIconPool().then(() => {
      container.querySelectorAll("[data-reaction]").forEach((btn) => {
        const glyph = btn.querySelector(".byte-msg-reaction-icon");
        if (glyph) renderIconValue(glyph, btn.dataset.reaction);
      });
    });
  }
}
