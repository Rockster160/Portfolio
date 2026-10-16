// Buddy hero — the "Tamagotchi" area at the top of the Byte page when
// the active conversation is mode=:buddy — plus the actions menu in the
// header, which is where everything Buddy can be asked to do without typing
// now lives. None of it injects a fake user message; they all fire server-side
// actions that produce a genuine Buddy-authored reply.
//
// The menu is one button and one popover: a root list, and a panel per choice
// that has its own options. A sub-panel REPLACES the root rather than opening
// beside it, which is why they're all `[data-actions-panel]` under one element
// and `showPanel` is the only thing that moves between them.

// Extension spelled out so node can load this module directly — esbuild is
// happy either way, and the actions-menu runner imports it unbundled.
import { quickOrder, NO_ROUTINES } from "./routine_order.js";
import { IDLE_FACE } from "./face_url.js";

const ROUTINES_URL = "/buddy/routines";

// Who wins when several standing states want the face at once (see
// `holdExpression`). Asleep outranks everything — a capped/unreachable Byte is
// out cold whatever else is true; the Whisper's own state is next; a board
// alert's "up to no good" face sits under both, so an open gate shows only
// while the pet is actually awake to look guilty about it. A dream is the
// weakest: its face is SOFT (see holdExpression), showing only while nothing
// else is held and the pet is resting on its idle face.
export const HOLD_PRIORITY = { sleep: 30, whisper: 20, alert: 10, dream: 0 };

function csrfToken() {
  const meta = document.querySelector('meta[name="csrf-token"]');
  return meta ? meta.getAttribute("content") : "";
}

async function postJSON(url, payload) {
  const res = await fetch(url, {
    method:      "POST",
    credentials: "same-origin",
    headers:     {
      "Content-Type": "application/json",
      "Accept":       "application/json",
      "X-CSRF-Token": csrfToken(),
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    console.warn("[buddy] quick action failed", res.status, await res.text().catch(() => ""));
    throw new Error(`HTTP ${res.status}`);
  }
  return res.json().catch(() => ({}));
}

function postQuickAction(payload) {
  return postJSON("/buddy/quick_action", payload);
}

async function fetchQuickRoutines() {
  const res = await fetch(ROUTINES_URL, {
    credentials: "same-origin",
    headers:     { Accept: "application/json" },
  });
  if (!res.ok) throw new Error(`http_${res.status}`);
  const data = await res.json().catch(() => null);
  return quickOrder(data?.routines);
}

export function initBuddyHero({ hero, menu, menuToggle, conversationIdFn, onStashArmed, faceUrl }) {
  if (!hero) return null;

  const charEl     = hero.querySelector(".byte-buddy-char");
  const faceEl     = hero.querySelector(".byte-buddy-face");
  const facePopover = hero.querySelector("[data-buddy-face-popover]");
  const panels     = menu ? Array.from(menu.querySelectorAll("[data-actions-panel]")) : [];
  const quickList  = menu ? menu.querySelector("[data-buddy-quick-list]") : null;

  // Only one panel is ever on screen. Naming the one to show — rather than
  // toggling `hidden` per panel at each call site — is what makes a sub-list
  // REPLACE the root instead of stacking on top of it.
  const showPanel = (name) => {
    panels.forEach((panel) => { panel.hidden = panel.dataset.actionsPanel !== name; });
  };

  const closeMenu = () => {
    if (!menu) return;
    menu.hidden = true;
    if (menuToggle) menuToggle.setAttribute("aria-expanded", "false");
  };

  // Always back to the root. The panel left showing belongs to a tap that has
  // long since been answered, and reopening onto it would hide the whole list.
  const openMenu = () => {
    if (!menu) return;
    showPanel("root");
    menu.hidden = false;
    if (menuToggle) menuToggle.setAttribute("aria-expanded", "true");
    refreshQuick();
  };

  const setActive = (isBuddy) => {
    hero.dataset.buddyActive = isBuddy ? "true" : "false";
    hero.hidden = !isBuddy;
    if (!isBuddy && facePopover) facePopover.hidden = true;
    // The actions are Buddy's, so the button that opens them is only offered
    // on a Buddy thread — a claude/bash conversation has nothing behind it.
    if (menuToggle) menuToggle.hidden = !isBuddy;
    if (!isBuddy) closeMenu();
  };

  // The pet wears up to three layers, strongest last:
  //
  //   1. MOOD (`restingExpression`) — the sentiment / [[mood:]] face, the
  //      resting default. A new mood or the idle reset changes it. A transient
  //      paint never updates it; a real one does.
  //   2. a HELD STATE — a condition that is TRUE RIGHT NOW and has to show
  //      until it stops being true: asleep, the Whisper hiding, the laundry
  //      gate open ("up to no good"). Keyed, so several can stand at once; the
  //      strongest wins and the mood underneath is remembered, not shown. The
  //      whole point is that a held state SURVIVES a mood change, the idle
  //      reset, and a transient overlay clearing — the things that used to
  //      revert it when state faces were painted transiently.
  //   3. a TRANSIENT overlay — "thinking" while a turn runs, the alarm flip —
  //      shown on top for a moment, then gone, falling back to the state or
  //      the mood beneath it.
  let restingExpression = hero.dataset.buddyAwakeExpression || "neutral";

  // key → { expression, priority, soft }. Highest priority showing; a later
  // hold at equal priority wins the tie (Map keeps insertion order). Empty = no
  // state stands and the mood shows.
  const holds = new Map();

  const topHold = (soft) => {
    let best = null;
    holds.forEach((h) => {
      if (h.soft !== soft) return;
      if (!best || h.priority >= best.priority) best = h;
    });
    return best;
  };

  // What SHOULD show when nothing transient is over it: the strongest standing
  // state, else a soft one (a dream's) while the mood is only idle, else the
  // resting mood. Any real mood beats a soft hold.
  const effectiveExpression = () => {
    const hard = topHold(false);
    if (hard) return hard.expression;
    const soft = restingExpression === IDLE_FACE ? topHold(true) : null;
    return soft?.expression || restingExpression;
  };

  const paint = (expression) => {
    hero.dataset.buddyExpression = String(expression);
    if (charEl) charEl.dataset.buddyExpression = String(expression);
    // The face is a single data-driven image, not a per-theme CSS rule: look up
    // this pet's resolved art for the expression and set it as the face layer's
    // background. `thinking` resolves server-side to a stand-in pose for a pet
    // with no thinking art, so the overlay is always a visible change here. A
    // companion is its images + sentiment map, with nothing to wire in CSS.
    if (faceEl) {
      const url = faceUrl && faceUrl(hero.dataset.buddyTheme, expression);
      faceEl.style.setProperty("--buddy-face-url", url ? `url("${url}")` : "none");
    }
    syncFaceStates();
  };

  const setExpression = (expression, opts = {}) => {
    if (!expression) return;
    // A real (non-transient) paint sets the MOOD. It is remembered underneath a
    // standing state but NOT shown over it — a cheer or a sentiment broadcast
    // mustn't wipe "asleep" or the open-gate face off the board. A transient
    // paint is a momentary overlay and changes neither layer.
    if (!opts.transient) {
      restingExpression = String(expression);
      // Whatever is held (or soft-held over an idle mood) decides the face.
      return paint(effectiveExpression());
    }
    paint(expression);
  };

  // Raise a standing state the pet must wear until it's cleared — asleep, the
  // Whisper hiding, a board alert's held face. `key` names the condition so it
  // can be lifted again; `priority` decides who wins when several stand at once
  // (sleep over an open gate, say). Re-raising the same key updates it.
  //
  // `soft` is a face that yields to everything: it shows only while no other
  // state is held and the mood is idle (a dream's thinking face).
  const holdExpression = (key, expression, priority = 0, { soft = false } = {}) => {
    if (!key || !expression) return;
    holds.set(String(key), { expression: String(expression), priority, soft });
    paint(effectiveExpression());
  };

  // The condition passed — drop its hold and fall back to whatever still
  // stands, or the resting mood when nothing does.
  const releaseExpression = (key) => {
    if (!holds.delete(String(key))) return;
    paint(effectiveExpression());
  };

  // Drop the "thinking" overlay and fall back to the standing state, or the
  // remembered mood when none stands. No-op unless the pet is actually
  // mid-thought, so a real face already showing is left alone.
  const clearThinking = () => {
    if (hero.dataset.buddyExpression === "thinking") paint(effectiveExpression());
  };

  // Force the face back to what should be showing, whatever it currently is.
  // Used to end a transient takeover (e.g. the timer-alarm face loop) that left
  // a non-"thinking" face on screen, which clearThinking won't undo.
  const restExpression = () => paint(effectiveExpression());

  const quickButton = (routine) => {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.dataset.quickRoutine = String(routine.id);
    btn.textContent = routine.name;
    if (routine.description) btn.title = routine.description;
    return btn;
  };

  // The one part of the list that comes from the server. The rows are already
  // rendered (see byte/show.html.erb), so this is a re-read on open rather
  // than a fill, and that is what makes a routine saved since this page loaded
  // show up without a reload.
  //
  // A failed fetch leaves the rendered rows standing and says nothing. It used
  // to write "Couldn't load those." into the panel, which was right when that
  // was the panel's whole content; here it would wipe a list that is already
  // correct over a request nobody asked for.
  const refreshQuick = async () => {
    if (!quickList) return;

    let routines = [];
    try {
      routines = await fetchQuickRoutines();
    } catch (_) {
      return;
    }

    quickList.textContent = "";
    // Empty means there genuinely aren't any, so it says the thing that would
    // actually produce one.
    if (routines.length === 0) {
      quickList.textContent = NO_ROUTINES;
      return;
    }
    routines.forEach((routine) => { quickList.appendChild(quickButton(routine)); });
  };

  // Runs server-side with no model turn, so there's no "thinking" flip to make
  // here — the steps post their own receipts as they go.
  const dispatchRoutine = async (id) => {
    const cid = currentConversationId();
    if (cid == null) return;
    closeMenu();
    try {
      await postJSON(`${ROUTINES_URL}/${id}/run`, { conversation_id: cid });
    } catch (_) { /* server logs the reason */ }
  };

  // "What now?" focused on a bucket (or Anything = unfiltered). Same server
  // action as the bare tap, just with a category.
  const dispatchSuggest = async (category) => {
    const cid = currentConversationId();
    if (cid == null) return;
    closeMenu();
    setExpression("thinking", { transient: true });
    try {
      await postQuickAction({ kind: "suggest", category, conversation_id: cid });
    } catch (_) { /* server logs the reason */ }
  };

  // Arm a brain-dump bucket: the person's NEXT message gets filed as an idea
  // (the server holds the latch). We just tell the composer to hint it.
  const dispatchStash = async (category) => {
    const cid = currentConversationId();
    if (cid == null) return;
    closeMenu();
    try {
      await postQuickAction({ kind: "stash", category, conversation_id: cid });
      if (onStashArmed) onStashArmed(category);
    } catch (_) { /* server logs the reason */ }
  };

  // ---- Debug face/theme picker (temporary) ----
  const openFace  = () => { if (facePopover) { facePopover.hidden = false; syncFaceStates(); } };
  const closeFace = () => { if (facePopover) facePopover.hidden = true; };

  // Theme swap is purely client-side here — it flips the hero's
  // data-buddy-theme, which the CSS keys the palette off, so a pet can be
  // previewed without touching the persisted user theme. The face is this pet's
  // own art, so repaint the current expression or the previous pet's face would
  // stay on screen.
  const setTheme = (theme) => {
    if (!theme) return;
    hero.dataset.buddyTheme = String(theme);
    paint(hero.dataset.buddyExpression || restingExpression);
  };

  // Reflect the live theme + expression back onto the picker buttons, and
  // show only the face grid for the live theme (each theme has a different
  // face set, so the picker must never offer faces the theme lacks).
  function syncFaceStates() {
    if (!facePopover) return;
    const theme = hero.dataset.buddyTheme;
    const expr  = hero.dataset.buddyExpression;
    facePopover.querySelectorAll("[data-buddy-theme-set]").forEach((b) => {
      b.setAttribute("aria-pressed", String(b.dataset.buddyThemeSet === theme));
    });
    facePopover.querySelectorAll("[data-buddy-face-choices]").forEach((grid) => {
      grid.hidden = grid.dataset.faceTheme !== theme;
    });
    facePopover.querySelectorAll("[data-face]").forEach((b) => {
      b.setAttribute("aria-pressed", String(b.dataset.face === expr));
    });
  }

  const currentConversationId = () => (conversationIdFn ? conversationIdFn() : null);

  // Fire any zero-arg quick action directly. Today / Affirmation /
  // What-now all just POST { kind: <action> } — the Rails-side handler
  // knows what prompt to send Buddy. Optimistic pet-to-thinking flip
  // gives immediate feedback since the outbound trigger bubble is
  // hidden by design.
  const dispatchAction = async (kind) => {
    const cid = currentConversationId();
    if (cid == null) return;
    setExpression("thinking", { transient: true });
    try {
      await postQuickAction({ kind: kind, conversation_id: cid });
    } catch (_) { /* server logs the reason; expression rebroadcasts on reply */ }
  };

  const dispatchCheckin = async (mood) => {
    const cid = currentConversationId();
    if (cid == null) return;
    closeMenu();
    setExpression("thinking", { transient: true });
    try {
      await postQuickAction({ kind: "checkin", mood: mood, conversation_id: cid });
    } catch (_) { /* server logs the reason */ }
  };

  // iOS reliability (mirrors the composer's Send-button fix): with the
  // keyboard up, tapping a menu button would first blur the textarea — the
  // keyboard retracts, the layout reflows, and the button slides out from
  // under the finger, so the click never lands. Cancelling the button's
  // pointerdown default keeps the input focused; the click still fires and the
  // keyboard stays up.
  const keepFocusOnButtonTap = (el) => {
    el?.addEventListener("pointerdown", (e) => {
      if (e.target.closest("button")) e.preventDefault();
    });
  };
  keepFocusOnButtonTap(menu);
  keepFocusOnButtonTap(menuToggle);

  if (menuToggle) {
    menuToggle.addEventListener("click", () => {
      if (menu && menu.hidden) openMenu();
      else closeMenu();
    });
  }

  // One listener for the whole menu, because every panel is inside it. A
  // choice that owns options swaps the panel; everything else acts and closes.
  if (menu) {
    menu.addEventListener("click", (e) => {
      if (e.target.closest("[data-actions-back]")) return showPanel("root");

      const action = e.target.closest("[data-buddy-action]");
      if (action) {
        const kind = action.dataset.buddyAction;
        if (kind === "suggest") return showPanel("suggest");
        if (kind === "stash") return showPanel("stash");
        if (kind === "checkin") return showPanel("checkin");
        // No markup offers this — the face picker is a debug tool with no
        // entry in the list. Wired here so adding one is the only step.
        if (kind === "facepick") { closeMenu(); return openFace(); }
        closeMenu();
        return dispatchAction(kind);
      }

      const routine = e.target.closest("[data-quick-routine]");
      if (routine) return dispatchRoutine(routine.dataset.quickRoutine);

      const suggest = e.target.closest("[data-suggest]");
      if (suggest) return dispatchSuggest(suggest.dataset.suggest);

      const stash = e.target.closest("[data-stash]");
      if (stash) return dispatchStash(stash.dataset.stash);

      const mood = e.target.closest("[data-mood]");
      if (mood) return dispatchCheckin(mood.dataset.mood);
    });

    // Tap anywhere outside closes it. The toggle is excluded because its own
    // handler has already run by the time this fires, and closing here would
    // undo the open it just did.
    document.addEventListener("click", (e) => {
      if (menu.hidden) return;
      if (menu.contains(e.target)) return;
      if (menuToggle && menuToggle.contains(e.target)) return;
      closeMenu();
    });
  }

  // Debug face/theme picker — sets expression/theme locally, stays open so
  // several can be tried in a row.
  if (facePopover) {
    facePopover.addEventListener("click", (e) => {
      // Close on any pick — the popover covers Byte, so you can't see the
      // result while it's open. Re-tap "Faces" to try another.
      const themeBtn = e.target.closest("[data-buddy-theme-set]");
      if (themeBtn) { setTheme(themeBtn.dataset.buddyThemeSet); closeFace(); return; }
      const faceBtn = e.target.closest("[data-face]");
      if (faceBtn) { setExpression(faceBtn.dataset.face); closeFace(); }
    });

    document.addEventListener("click", (e) => {
      if (facePopover.hidden) return;
      if (facePopover.contains(e.target)) return;
      if (e.target.closest('[data-buddy-action="facepick"]')) return;
      closeFace();
    });
  }

  return {
    setActive,
    setExpression,
    holdExpression,
    releaseExpression,
    setTheme,
    clearThinking,
    restExpression,
    // Drive the face off Buddy's ACTUAL reply as its text starts streaming:
    // drop "thinking", and if the reply opens with a [[mood:]], wear that face.
    // Deliberately ignores everything that ISN'T the reply bubble streaming
    // real words, so the pet keeps thinking until then:
    //   * non-reply messages (the "Today"/check-in action chip, stash/activity
    //     chips, receipts, hidden triggers) — only kind buddy/buddy_reply count;
    //   * the "…"/"..." streaming placeholder — that IS "still thinking".
    onReplyStreaming(message) {
      const kind = message && message.metadata && message.metadata.kind;
      if (kind !== "buddy" && kind !== "buddy_reply") return;

      const text = String((message && message.body) || "");
      const stripped = text.replace(/\[\[[^\]]*\]\]/g, "").trim();
      if (!stripped || /^[.…]+$/.test(stripped)) return; // placeholder / no words yet

      const m = text.match(/\[\[\s*mood:\s*([a-z_]+)\s*\]\]/i);
      if (m) setExpression(m[1].toLowerCase());
      else clearThinking();
    },
    onModeChange(newMode) {
      setActive(newMode === "buddy");
    },
  };
}
