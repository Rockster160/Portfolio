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

const ROUTINES_URL = "/buddy/routines";

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
  if (!res.ok) return [];
  const data = await res.json().catch(() => null);
  return quickOrder(data?.routines);
}

export function initBuddyHero({ hero, menu, menuToggle, conversationIdFn, onStashArmed }) {
  if (!hero) return null;

  const charEl     = hero.querySelector(".byte-buddy-char");
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
  // long since been answered, and reopening onto it would hide the other four.
  const openMenu = () => {
    if (!menu) return;
    showPanel("root");
    menu.hidden = false;
    if (menuToggle) menuToggle.setAttribute("aria-expanded", "true");
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

  // The pet has two layers: a persistent MOOD and a transient "thinking"
  // overlay shown while a turn is in flight. `restingExpression` remembers the
  // mood so that when thinking clears we fall back to exactly the face Buddy
  // was wearing — never a hardcoded default. A transient paint never updates
  // it; a real one does.
  let restingExpression = hero.dataset.buddyAwakeExpression || "neutral";

  const paint = (expression) => {
    hero.dataset.buddyExpression = String(expression);
    if (charEl) charEl.dataset.buddyExpression = String(expression);
    syncFaceStates();
  };

  const setExpression = (expression, opts = {}) => {
    if (!expression) return;
    if (!opts.transient) restingExpression = String(expression);
    paint(expression);
  };

  // Drop the "thinking" overlay and fall back to the remembered mood. No-op
  // unless the pet is actually mid-thought, so a real mood already showing is
  // left alone. Called the instant reply text starts streaming.
  const clearThinking = () => {
    if (hero.dataset.buddyExpression === "thinking") paint(restingExpression);
  };

  // Force the face back to the remembered mood, whatever it's currently
  // showing. Used to end a transient takeover (e.g. the timer-alarm face loop)
  // that left a non-"thinking" face on screen, which clearThinking won't undo.
  const restExpression = () => paint(restingExpression);

  // The only panel filled from the server. Shown first and populated after, so
  // a slow request shows the panel with "loading" rather than swallowing the
  // tap and looking broken.
  const openQuick = async () => {
    if (!quickList) return;

    showPanel("quick");
    quickList.textContent = "Loading…";
    let routines = [];
    try {
      routines = await fetchQuickRoutines();
    } catch (_) {
      quickList.textContent = "Couldn't load those.";
      return;
    }

    if (routines.length === 0) {
      // Empty here now means there genuinely aren't any, so it says the thing
      // that would actually produce one.
      quickList.textContent = NO_ROUTINES;
      return;
    }

    quickList.textContent = "";
    routines.forEach((r) => {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.dataset.quickRoutine = String(r.id);
      btn.textContent = r.name;
      if (r.description) btn.title = r.description;
      quickList.appendChild(btn);
    });
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

  // Theme swap is purely client-side here — it just flips the hero's
  // data-buddy-theme, which the CSS keys palette + body + faces off of, so
  // Moss can be previewed without touching the persisted user theme.
  const setTheme = (theme) => {
    if (!theme) return;
    hero.dataset.buddyTheme = String(theme);
    syncFaceStates();
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
        if (kind === "quick") return openQuick();
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
