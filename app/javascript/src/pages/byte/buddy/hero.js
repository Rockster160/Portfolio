// Buddy hero — the "Tamagotchi" area at the top of the Byte page when
// the active conversation is mode=:buddy. Shows the character, its
// current expression, and a row of small quick-prompt chips that just
// pre-fill the composer with a Buddy-directed message and submit.
//
// State comes from three sources:
//   1. Initial data-attributes on the hero element (set by the server).
//   2. ConversationManager tells us when the active mode changes.
//   3. MonitorChannel :buddy_expression broadcasts.

export function initBuddyHero({ hero, input, sendHandler }) {
  if (!hero) return null;

  const charEl = hero.querySelector(".byte-buddy-char");
  const quickActions = hero.querySelector("[data-buddy-quick-actions]");

  const setActive = (isBuddy) => {
    hero.dataset.buddyActive = isBuddy ? "true" : "false";
    hero.hidden = !isBuddy;
  };

  const setExpression = (expression) => {
    if (!expression) return;
    hero.dataset.buddyExpression = String(expression);
    if (charEl) charEl.dataset.buddyExpression = String(expression);
  };

  // Wire quick-action chips: each has data-buddy-quickfill="text". Tap
  // fills the composer and (if a sendHandler is provided) auto-submits.
  if (quickActions) {
    quickActions.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-buddy-quickfill]");
      if (!btn) return;
      const fill = btn.dataset.buddyQuickfill || "";
      if (!input) return;

      input.value = fill;
      // Focus and place cursor at end so the user can extend "Log this: "
      // etc. inline. If the chip is a completed prompt (ends without a
      // colon or blank tail), also auto-send.
      input.focus();
      input.setSelectionRange(fill.length, fill.length);

      const looksIncomplete = fill.endsWith(":") || fill.endsWith(": ") || fill.endsWith(" ");
      if (!looksIncomplete && sendHandler) sendHandler(fill);
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
