// What counts as a TAP on one of the hero chips — the timers on the left, the
// background processes on the right. Shared, because both stacks had both of
// the bugs below and a rule about what a tap is belongs in one place.
//
// A plain `click` listener is wrong here for two reasons, and each one was
// reported the day the × replaced the swipe (Rocco, 17 Sep):
//
// 1. "the whole layout changes and the x moves and then the click gets
//    registered on the alert itself which opens the tab instead."
//    Pressing the × re-renders the strip inside the handler, so the DOM under
//    the finger is replaced mid-gesture. What arrives afterwards — the mouse
//    events a touch synthesises, or a `click` retargeted to the nearest
//    ancestor the press and the release still share — lands on a chip that was
//    not there when the press began, and that chip opens its link.
//
// 2. "swiping is now getting triggered as a click ... A drag on it should not
//    be counted as a click." Dragging the strip, or scrolling with a finger
//    that starts on a chip, ends in a `click` on that chip.
//
// Both are the same missing rule: a tap belongs to the element the gesture
// STARTED on, and a gesture that travelled is not a tap. So a click is only
// honoured when this element saw the `pointerdown` that opened the gesture and
// the pointer stayed put. Nothing here is time-based — a click that arrives
// late is fine, a click from a gesture that began somewhere else never is.

// About a millimetre and a half. Under it a finger is holding still; over it
// somebody is dragging, and every list on a phone reads it the same way.
export const TAP_SLOP_PX = 8;

export function onChipTap(el, handler) {
  let opened = null;

  el.addEventListener("pointerdown", (e) => {
    opened = {
      x: e.clientX,
      y: e.clientY,
      // A gesture that began on a control is that control's, wherever it ends.
      // Sliding off the × onto the chip body must not open a tab.
      control: Boolean(e.target?.closest?.("a, button")),
    };
  });

  const forget = () => { opened = null; };
  el.addEventListener("pointercancel", forget);

  el.addEventListener("click", (e) => {
    const from = opened;
    opened = null;

    // `detail` is 0 for a click no pointer made: Enter on a focused button,
    // or one dispatched by script. Those have no gesture to check and are the
    // whole of this control's keyboard support.
    if (e.detail === 0) return handler(e);
    if (from == null) return;
    if (from.control && !isControl(el)) return;

    const dx = (e.clientX ?? from.x) - from.x;
    const dy = (e.clientY ?? from.y) - from.y;
    if (Math.hypot(dx, dy) > TAP_SLOP_PX) return;

    handler(e);
  });
}

function isControl(el) {
  return el.tag === "button" || el.tagName === "BUTTON" || el.tagName === "A";
}
