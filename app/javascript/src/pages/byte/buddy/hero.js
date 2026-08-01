// Buddy hero — the "Tamagotchi" area at the top of the Byte page when
// the active conversation is mode=:buddy. Shows the character with
// live expression state and two real quick-action chips (Today +
// Check-in). Neither injects a fake user message; both fire server-
// side actions that produce a genuine Buddy-authored reply.

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

async function fetchPinnedRoutines() {
  const res = await fetch(ROUTINES_URL, {
    credentials: "same-origin",
    headers:     { Accept: "application/json" },
  });
  if (!res.ok) return [];
  const data = await res.json().catch(() => null);
  return (data?.routines || [])
    .filter((r) => r.enabled && r.position != null)
    .sort((a, b) => a.position - b.position);
}

export function initBuddyHero({ hero, conversationIdFn, onStashArmed }) {
  if (!hero) return null;

  const charEl        = hero.querySelector(".byte-buddy-char");
  const quickActions  = hero.querySelector("[data-buddy-quick-actions]");
  const moodPopover    = hero.querySelector("[data-buddy-mood-popover]");
  const facePopover    = hero.querySelector("[data-buddy-face-popover]");
  const stashPopover   = hero.querySelector("[data-buddy-stash-popover]");
  const suggestPopover = hero.querySelector("[data-buddy-suggest-popover]");
  const quickPopover   = hero.querySelector("[data-buddy-quick-popover]");
  const quickList      = hero.querySelector("[data-buddy-quick-list]");

  const setActive = (isBuddy) => {
    hero.dataset.buddyActive = isBuddy ? "true" : "false";
    hero.hidden = !isBuddy;
    if (!isBuddy && moodPopover) moodPopover.hidden = true;
    if (!isBuddy && facePopover) facePopover.hidden = true;
    if (!isBuddy && stashPopover) stashPopover.hidden = true;
    if (!isBuddy && suggestPopover) suggestPopover.hidden = true;
    if (!isBuddy && quickPopover) quickPopover.hidden = true;
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

  const openMood  = () => { if (moodPopover) moodPopover.hidden = false; };
  const closeMood = () => { if (moodPopover) moodPopover.hidden = true;  };

  const openStash  = () => { if (stashPopover) stashPopover.hidden = false; };
  const closeStash = () => { if (stashPopover) stashPopover.hidden = true;  };

  const openSuggest  = () => { if (suggestPopover) suggestPopover.hidden = false; };
  const closeSuggest = () => { if (suggestPopover) suggestPopover.hidden = true;  };

  const closeQuick = () => { if (quickPopover) quickPopover.hidden = true; };

  // The only popover filled from the server. Opened first and populated after,
  // so a slow request shows the panel with "loading" rather than swallowing the
  // tap and looking broken.
  const openQuick = async () => {
    if (!quickPopover || !quickList) return;

    quickPopover.hidden = false;
    quickList.textContent = "Loading…";
    let routines = [];
    try {
      routines = await fetchPinnedRoutines();
    } catch (_) {
      quickList.textContent = "Couldn't load those.";
      return;
    }

    if (routines.length === 0) {
      // Says what to DO about it. An empty grid with no explanation reads as
      // broken, and pinning happens somewhere they aren't currently looking.
      quickList.textContent = "Nothing pinned yet — pin a routine in the drawer.";
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
    closeQuick();
    try {
      await postJSON(`${ROUTINES_URL}/${id}/run`, { conversation_id: cid });
    } catch (_) { /* server logs the reason */ }
  };

  // "What now?" focused on a bucket (or Anything = unfiltered). Same server
  // action as the bare tap, just with a category.
  const dispatchSuggest = async (category) => {
    const cid = currentConversationId();
    if (cid == null) return;
    closeSuggest();
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
    closeStash();
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
    closeMood();
    setExpression("thinking", { transient: true });
    try {
      await postQuickAction({ kind: "checkin", mood: mood, conversation_id: cid });
    } catch (_) { /* server logs the reason */ }
  };

  // iOS reliability (mirrors the composer's Send-button fix): with the
  // keyboard up, tapping a hero button would first blur the textarea — the
  // keyboard retracts, the hero shrinks out of its focused side-by-side
  // layout, and the button slides out from under the finger, so the click
  // never lands. Cancelling the button's pointerdown default keeps the input
  // focused; the click still fires and the keyboard stays up. Applied to the
  // quick chips and the mood popover (Check-in) buttons they open.
  const keepFocusOnButtonTap = (el) => {
    el?.addEventListener("pointerdown", (e) => {
      if (e.target.closest("button")) e.preventDefault();
    });
  };
  keepFocusOnButtonTap(quickActions);
  keepFocusOnButtonTap(moodPopover);

  // Quick action chips. Zero-arg actions fire directly. Check-in opens
  // the mood popover so we can attach the picked mood to the server call.
  if (quickActions) {
    quickActions.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-buddy-action]");
      if (!btn) return;
      const action = btn.dataset.buddyAction;
      // Opening one closes the rest — they all cover the pet, so two at once is
      // just a stack.
      const others = { checkin: closeMood, stash: closeStash, suggest: closeSuggest, facepick: closeFace, quick: closeQuick };
      Object.entries(others).forEach(([name, close]) => { if (name !== action) close(); });

      if (action === "checkin") return openMood();
      if (action === "stash") return openStash();
      if (action === "suggest") return openSuggest();
      if (action === "facepick") return openFace();
      if (action === "quick") return openQuick();
      dispatchAction(action);
    });
  }

  // "What now?" bucket popover — one tap fires the focused suggestion.
  if (suggestPopover) {
    keepFocusOnButtonTap(suggestPopover);
    suggestPopover.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-suggest]");
      if (!btn) return;
      dispatchSuggest(btn.dataset.suggest);
    });

    document.addEventListener("click", (e) => {
      if (suggestPopover.hidden) return;
      if (suggestPopover.contains(e.target)) return;
      if (e.target.closest('[data-buddy-action="suggest"]')) return;
      closeSuggest();
    });
  }

  // Pinned-routine grid — one tap runs it + closes.
  if (quickPopover) {
    keepFocusOnButtonTap(quickPopover);
    quickPopover.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-quick-routine]");
      if (!btn) return;
      dispatchRoutine(btn.dataset.quickRoutine);
    });

    document.addEventListener("click", (e) => {
      if (quickPopover.hidden) return;
      if (quickPopover.contains(e.target)) return;
      if (e.target.closest('[data-buddy-action="quick"]')) return;
      closeQuick();
    });
  }

  // Stash bucket popover — one tap arms the bucket + closes.
  if (stashPopover) {
    keepFocusOnButtonTap(stashPopover);
    stashPopover.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-stash]");
      if (!btn) return;
      dispatchStash(btn.dataset.stash);
    });

    document.addEventListener("click", (e) => {
      if (stashPopover.hidden) return;
      if (stashPopover.contains(e.target)) return;
      if (e.target.closest('[data-buddy-action="stash"]')) return;
      closeStash();
    });
  }

  // Mood popover — one tap posts + closes.
  if (moodPopover) {
    moodPopover.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-mood]");
      if (!btn) return;
      const mood = btn.dataset.mood;
      dispatchCheckin(mood);
    });

    // Tap anywhere outside the popover closes it.
    document.addEventListener("click", (e) => {
      if (moodPopover.hidden) return;
      if (moodPopover.contains(e.target)) return;
      if (e.target.closest('[data-buddy-action="checkin"]')) return;
      closeMood();
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
