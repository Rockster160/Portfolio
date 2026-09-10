// Byte reloading itself once an update has landed AND nobody is using the app.
//
// The "!" on the reload button is the ordinary path, and it works when someone
// is there to press it. What it doesn't cover is the tab that has been open on
// a desk since yesterday, or the phone in a pocket: nothing gets tapped, so the
// shell just goes on being the old one, and the first thing the person does
// after picking it up runs against code that was replaced hours ago.
//
// A reload is not free — it throws away scroll position, a half-typed message,
// and whatever was open on top of the thread — so "not using it" is drawn
// narrowly and every condition has to hold at once:
//
//   * five minutes since the last touch, key, pointer move or scroll
//   * the window doesn't have focus, or the page is hidden outright
//   * the caller's own `quiet()`: parked at the bottom of the thread, nothing
//     open over it, nothing queued, nothing typed
//
// Sitting still is NOT enough on its own. Reading a long reply is five minutes
// of no input with the app right there in front of them, and yanking the page
// out from under that is the exact thing this must never do — hence the focus
// condition, which is what separates "idle" from "unattended".

export const IDLE_MS = 5 * 60 * 1000;

// How often the conditions get re-asked. A background tab has its timers
// throttled to about a minute, which is well inside the tolerance here: this
// decides when an ALREADY-stale shell gets replaced, so being a minute late
// costs nothing.
export const CHECK_MS = 30 * 1000;

// Anything a person does with their hands. `scroll` and `focus` are listened
// for with capture because neither bubbles from the element that emits it, and
// the thread's own scroll container is well inside the page.
const ACTIVITY = [
  "pointerdown",
  "pointermove",
  "pointerup",
  "touchstart",
  "touchmove",
  "keydown",
  "wheel",
  "scroll",
  "input",
  "focus",
];

// The whole rule, as a pure function so it can be asked directly rather than
// inferred from whether a reload happened.
export function idleReloadDecision({
  idleFor,
  hidden,
  focused,
  online,
  quiet,
  idleMs = IDLE_MS,
}) {
  if (!(idleFor >= idleMs)) return "recently-used";
  if (!hidden && focused) return "watching";
  // `hardReload` empties every cache BEFORE it navigates, and a navigation with
  // no network never lands — it doesn't throw, it simply doesn't happen. The
  // page that would be left behind is worse than the stale one this is trying
  // to replace, so offline declines and the "!" stays for a tap.
  if (online === false) return "offline";
  if (!quiet) return "unsettled";

  return "reload";
}

export function initIdleReload({
  quiet,
  reload,
  idleMs = IDLE_MS,
  checkMs = CHECK_MS,
  now = () => Date.now(),
}) {
  let lastActivity = now();
  let timer = null;

  const touch = () => {
    lastActivity = now();
  };

  ACTIVITY.forEach((type) =>
    window.addEventListener(type, touch, { capture: true, passive: true }),
  );
  // Coming back to the app is using it, even though no pointer moved to do it.
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) touch();
  });

  function decide() {
    return idleReloadDecision({
      idleFor: now() - lastActivity,
      hidden: !!document.hidden,
      focused: typeof document.hasFocus === "function" ? document.hasFocus() : true,
      online: navigator.onLine,
      quiet: !!quiet(),
      idleMs,
    });
  }

  function tick() {
    // Disarmed means the decision has already been made once. The reload below
    // navigates rather than returning, so a timer still holding a reference to
    // this would otherwise empty every cache a second time on its way out.
    if (!timer) return;
    if (decide() !== "reload") return;

    // Once. The navigation is in flight from here and the timer would otherwise
    // fire again behind it, nuking the caches a second time.
    disarm();
    reload();
  }

  function arm() {
    if (timer) return;
    timer = setInterval(tick, checkMs);
  }

  function disarm() {
    if (!timer) return;
    clearInterval(timer);
    timer = null;
  }

  return { arm, disarm, decide, tick, armed: () => !!timer };
}
