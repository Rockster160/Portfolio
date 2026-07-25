// Buddy hero — the "Tamagotchi" area at the top of the Byte page when
// the active conversation is mode=:buddy. Shows the character with
// live expression state and two real quick-action chips (Today +
// Check-in). Neither injects a fake user message; both fire server-
// side actions that produce a genuine Buddy-authored reply.

async function postQuickAction(payload) {
  const csrfMeta = document.querySelector('meta[name="csrf-token"]');
  const csrf = csrfMeta ? csrfMeta.getAttribute("content") : "";
  const res = await fetch("/buddy/quick_action", {
    method:      "POST",
    credentials: "same-origin",
    headers:     {
      "Content-Type": "application/json",
      "Accept":       "application/json",
      "X-CSRF-Token": csrf,
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    console.warn("[buddy] quick action failed", res.status, await res.text().catch(() => ""));
    throw new Error(`HTTP ${res.status}`);
  }
  return res.json().catch(() => ({}));
}

export function initBuddyHero({ hero, conversationIdFn }) {
  if (!hero) return null;

  const charEl        = hero.querySelector(".byte-buddy-char");
  const quickActions  = hero.querySelector("[data-buddy-quick-actions]");
  const moodPopover   = hero.querySelector("[data-buddy-mood-popover]");

  const setActive = (isBuddy) => {
    hero.dataset.buddyActive = isBuddy ? "true" : "false";
    hero.hidden = !isBuddy;
    if (!isBuddy && moodPopover) moodPopover.hidden = true;
  };

  const setExpression = (expression) => {
    if (!expression) return;
    hero.dataset.buddyExpression = String(expression);
    if (charEl) charEl.dataset.buddyExpression = String(expression);
  };

  const openMood  = () => { if (moodPopover) moodPopover.hidden = false; };
  const closeMood = () => { if (moodPopover) moodPopover.hidden = true;  };

  const currentConversationId = () => (conversationIdFn ? conversationIdFn() : null);

  // Fire any zero-arg quick action directly. Today / Affirmation /
  // What-now all just POST { kind: <action> } — the Rails-side handler
  // knows what prompt to send Buddy. Optimistic pet-to-thinking flip
  // gives immediate feedback since the outbound trigger bubble is
  // hidden by design.
  const dispatchAction = async (kind) => {
    const cid = currentConversationId();
    if (cid == null) return;
    setExpression("thinking");
    try {
      await postQuickAction({ kind: kind, conversation_id: cid });
    } catch (_) { /* server logs the reason; expression rebroadcasts on reply */ }
  };

  const dispatchCheckin = async (mood) => {
    const cid = currentConversationId();
    if (cid == null) return;
    closeMood();
    setExpression("thinking");
    try {
      await postQuickAction({ kind: "checkin", mood: mood, conversation_id: cid });
    } catch (_) { /* server logs the reason */ }
  };

  // Quick action chips. Zero-arg actions fire directly. Check-in opens
  // the mood popover so we can attach the picked mood to the server call.
  if (quickActions) {
    quickActions.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-buddy-action]");
      if (!btn) return;
      const action = btn.dataset.buddyAction;
      if (action === "checkin") { openMood(); return; }
      dispatchAction(action);
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

  return {
    setActive,
    setExpression,
    onModeChange(newMode) {
      setActive(newMode === "buddy");
    },
  };
}
