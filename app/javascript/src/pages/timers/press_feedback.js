// What a press looks like while its request is out, and how it ended. Every
// mutation goes through api.js `request`, which hands its promise to `track`;
// the element that was just pressed picks it up, so no call site has to know.
//
// A request joins the press when it starts within JOIN_MS of the tap, or while
// that press still has a request out, so a chain (create, then start) reads as
// one press. The press settles SETTLE_MS after its last request comes back,
// leaving room for the next link of a chain to start first.
//
//   is-press-pending  something is still out (shown after PENDING_DELAY_MS, so
//                     a quick answer doesn't flicker)
//   is-press-done     every request answered OK
//   is-press-queued   offline: it's saved and will send on reconnect
//   is-press-failed   the server said no, or nothing came back
//
// A press with no request behind it (opening a menu) gets no state at all.

const PRESSABLE = "button, a[href], [role=button], .timer-card";
const JOIN_MS = 400;
const SETTLE_MS = 80;
const PENDING_DELAY_MS = 120;
const SHOW_MS = { done: 900, queued: 1800, failed: 1800 };
const RANK = { done: 0, queued: 1, failed: 2 };
const STATE_CLASSES = ["is-press-pending", "is-press-done", "is-press-queued", "is-press-failed"];

let current = null;

// Pointerdown as well as click: a dial sends its request on pointerup, before
// the click arrives. Click alone covers the keyboard.
export function watchPresses(doc = document) {
  doc.addEventListener("pointerdown", (e) => press(e.target), true);
  doc.addEventListener("click", (e) => {
    const el = press(e.target);
    // A link has no request to wait on: it's pending until the next page
    // replaces this one.
    if (el?.matches("a[href]") && isNavigation(e, el)) setState(el, "is-press-pending");
  }, true);
}

function press(from) {
  const el = from.closest?.(PRESSABLE);
  if (!el || el.disabled) return null;
  if (current?.el !== el || !(current.inflight > 0)) current = newPress(el);
  current.at = performance.now();
  return el;
}

// `run` returns a promise resolving to `{ result, outcome }`, outcome one of
// :done / :queued / :failed. Resolves to the bare result for the caller.
export function track(run) {
  const press = joinable();
  if (!press) return run().then(({ result }) => result);

  begin(press);
  return run().then(({ result, outcome }) => {
    end(press, outcome);
    return result;
  });
}

function newPress(el) {
  const timerId = el.closest("[data-timer-id]")?.dataset.timerId;
  return { el, timerId, at: 0, inflight: 0, outcome: null, pendingTimer: null, settleTimer: null };
}

// The element to draw on. A card the board remounted mid-press is a new node,
// so a press inside a card falls back to whichever card holds that timer now.
function target(press) {
  if (press.el.isConnected) return press.el;
  if (!press.timerId) return null;
  return document.querySelector(`.timer-card[data-timer-id="${press.timerId}"]`);
}

function joinable() {
  if (!current || !target(current)) return null;
  if (current.inflight > 0 || current.settleTimer) return current;
  return performance.now() - current.at < JOIN_MS ? current : null;
}

function begin(press) {
  clearTimeout(press.settleTimer);
  press.settleTimer = null;
  press.inflight += 1;
  if (press.inflight === 1 && !press.pendingTimer) {
    press.pendingTimer = setTimeout(() => setState(target(press), "is-press-pending"), PENDING_DELAY_MS);
  }
}

function end(press, outcome) {
  press.inflight -= 1;
  if (!press.outcome || RANK[outcome] > RANK[press.outcome]) press.outcome = outcome;
  if (press.inflight > 0) return;

  press.settleTimer = setTimeout(() => settle(press), SETTLE_MS);
}

function settle(press) {
  clearTimeout(press.pendingTimer);
  const outcome = press.outcome || "done";
  const el = target(press);
  if (current === press) current = null;
  if (!el) return;

  setState(el, `is-press-${outcome}`);
  setTimeout(() => el.classList.remove(`is-press-${outcome}`), SHOW_MS[outcome]);
}

function setState(el, cls) {
  if (!el) return;
  el.classList.remove(...STATE_CLASSES);
  // A reflow between the two, so pressing the same thing again replays the
  // animation instead of leaving it where it stopped.
  void el.offsetWidth;
  el.classList.add(cls);
}

function isNavigation(e, el) {
  const href = el.getAttribute("href");
  if (!href || href === "#" || href.startsWith("#")) return false;
  if (el.target && el.target !== "_self") return false;
  return !(e.metaKey || e.ctrlKey || e.shiftKey || e.altKey);
}
