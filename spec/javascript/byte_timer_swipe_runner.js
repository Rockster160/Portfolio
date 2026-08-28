// Drives Buddy's timer chips through a swipe-to-cancel and prints what the
// stack looked like at each step, as JSON for byte_timer_swipe_spec.rb.
//
// Everything the module touches is stubbed and recorded rather than performed:
// the chips are plain objects that remember their listeners, so a swipe is
// three synthetic pointer events, and `fetch` is a script the test sets per
// step so a DELETE can be made to fail on demand.

// The module warns on a failed cancel, which is correct and which this file
// causes on purpose. Left on, the stack trace prints the whole bundled data URL.
console.warn = () => {};

const requests = [];
let fetchPlan = () => ({ ok: true, json: async () => ({}) });

globalThis.fetch = async (url, opts = {}) => {
  const method = opts.method || "GET";
  requests.push(`${method} ${url}`);
  const res = fetchPlan(url, method);
  if (res instanceof Error) throw res;
  return res;
};

globalThis.localStorage = {
  store: {},
  getItem(k) { return this.store[k] ?? null; },
  setItem(k, v) { this.store[k] = String(v); },
};

// Timers the module schedules. Held rather than run, so the runner decides when
// the cancel-failed flash clears.
const pendingTimeouts = [];

globalThis.window = {
  setInterval: () => 1,
  clearInterval: () => {},
  setTimeout: (fn) => {
    pendingTimeouts.push(fn);
    return pendingTimeouts.length;
  },
  addEventListener: () => {},
  removeEventListener: () => {},
};

function fakeElement(tag) {
  return {
    tag,
    className:   "",
    textContent: "",
    dataset:     {},
    listeners:   {},
    children:    [],
    style:       { setProperty() {} },
    appendChild(child) { this.children.push(child); },
    addEventListener(name, fn) { this.listeners[name] = fn; },
    setPointerCapture() {},
    releasePointerCapture() {},
    hasPointerCapture() { return false; },
  };
}

// Recorded, not ignored: while a timer rings the module puts a capture-phase
// `pointerdown` on the document (armAck), and a tap on the chip fires BOTH that
// and the chip's own handler. Modelling only one of them would test a tap that
// doesn't happen.
const docListeners = {};

globalThis.document = {
  createElement: fakeElement,
  // Selector-aware: the alarm reads the hero's `dataset.buddyTheme` to pick a
  // face, and apiCall reads the CSRF meta. One shape can't answer both.
  querySelector: (sel) => (
    sel === "[data-buddy-hero]"
      ? { dataset: { buddyTheme: "byte" } }
      : { getAttribute: () => "csrf" }
  ),
  addEventListener: (name, fn) => { docListeners[name] = fn; },
  removeEventListener: (name) => { delete docListeners[name]; },
};

const container = {
  hidden:   false,
  children: [],
  set innerHTML(_v) { this.children = []; },
  get innerHTML() { return ""; },
  appendChild(child) { this.children.push(child); },
  querySelector: () => null,
};

// Bundled rather than imported directly: `timers.js` reaches for "./alarm"
// with no extension, which is what the rest of app/javascript does and what
// esbuild resolves for the real build. Node's ESM loader will not, so the
// alternative to bundling here is an extension on one import for the sake of a
// test, out of step with every other file.
const { build } = await import("esbuild");
const bundled = await build({
  entryPoints: [new URL("../../app/javascript/src/pages/byte/buddy/timers.js", import.meta.url).pathname],
  bundle:      true,
  format:      "esm",
  write:       false,
  logLevel:    "silent",
});
const { initBuddyTimers } = await import(
  `data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].text).toString("base64")}`
);

// A ringing timer starts the alarm, which paints Buddy's face.
const hero = { dataset: {}, setExpression() {} };
const stack = initBuddyTimers({ container, hero, isBuddyActiveFn: () => true });

// A running countdown with ten minutes left, as the server serializes one.
function timerPayload(over = {}) {
  return {
    id:            94,
    name:          "Quiet time",
    timer_page_id: 2,
    started_at:    new Date(Date.now() - 60_000).toISOString(),
    end_at:        new Date(Date.now() + 600_000).toISOString(),
    duration_ms:   660_000,
    ...over,
  };
}

// The same timer, past its end_at — which is what makes the chip ring. The
// countdown reaching zero is the moment, not the server's word for it, so
// `fired_at` being absent is the normal state for the first few seconds.
function ringingPayload(over = {}) {
  return timerPayload({ end_at: new Date(Date.now() - 5_000).toISOString(), ...over });
}

async function reset(payload = timerPayload()) {
  pendingTimeouts.length = 0;
  fetchPlan = (url) => ({
    ok:   true,
    json: async () => (url === "/buddy/timers" ? { page_id: 2, timers: [payload] } : {}),
  });
  await stack.hydrate();
  requests.length = 0;
}

// A swipe: press, drag past the threshold, release.
function swipe(chip) {
  chip.listeners.pointerdown({ clientX: 0, pointerId: 1 });
  chip.listeners.pointermove({ clientX: 130, pointerId: 1 });
  chip.listeners.pointerup({ clientX: 130, pointerId: 1 });
}

// A tap: press and release without moving. The document's capture-phase
// handler runs first when one is armed, exactly as the browser would.
function tap(chip) {
  docListeners.pointerdown?.({ clientX: 0, pointerId: 1 });
  chip.listeners.pointerdown({ clientX: 0, pointerId: 1 });
  chip.listeners.pointerup({ clientX: 0, pointerId: 1 });
}

const view = () => container.children.map((c) => ({
  id:      c.dataset.timerId,
  pending: c.dataset.pending ?? null,
  wired:   Object.keys(c.listeners).length > 0,
}));

const out = {};

// ---- the DELETE never lands ----------------------------------------------
// Prod timer 94: swiped away, gone from the corner, and it rang an hour later.
await reset();
let deferred = null;
fetchPlan = () => new Error("offline");
swipe(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.failed_requests = [...requests];
out.after_failed_swipe = view();
// The flash is temporary; the chip underneath is not.
pendingTimeouts.forEach((fn) => fn());
out.after_flash_clears = view();

// ---- the DELETE lands ------------------------------------------------------
await reset();
fetchPlan = () => ({ ok: true, json: async () => ({}) });
swipe(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.ok_requests = [...requests];
out.after_ok_swipe = view();

// ---- while it is still in the air -----------------------------------------
await reset();
let release = null;
fetchPlan = () => ({
  ok:   true,
  json: () => new Promise((r) => { release = () => r({}); }),
});
swipe(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.in_flight = view();
// A second swipe while the first is out must not fire a second DELETE.
requests.length = 0;
if (container.children[0]?.listeners?.pointerdown) swipe(container.children[0]);
out.second_swipe_requests = [...requests];
release?.();
await new Promise((r) => setTimeout(r, 0));
out.after_release = view();

// ---- tapping a chip that is RINGING ---------------------------------------
// It used to pause, which left a countdown with nowhere to go parked at zero.
//
// The ring has to ARRIVE rather than be hydrated: one already past its end_at
// when the app opens counts as acknowledged (the person was away and got a
// push), so it never starts the alarm and never arms the ack. Reaching it by
// broadcast is the real path — the countdown crossing zero while somebody is
// looking at it.
await reset();
fetchPlan = () => ({ ok: true, json: async () => ({}) });
stack.applyBroadcast({ data: { timer: ringingPayload() } });
out.ringing_state = view();
out.ack_armed_while_ringing = Object.keys(docListeners);
tap(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.ringing_tap_requests = [...requests];
out.after_ringing_tap = view();

// Once the server has stamped `fired_at` the ack has something to confirm, so
// BOTH calls go out. The chip still has to end up gone: a confirm landing
// after the cancel must not put it back, which is the shape that resurrects a
// chip nobody is expecting.
await reset();
fetchPlan = (url) => ({
  ok:   true,
  json: async () => (
    url.endsWith("/confirm")
      ? { ...timerPayload(), started_at: null, end_at: null, confirmed_at: new Date().toISOString() }
      : {}
  ),
});
stack.applyBroadcast({
  data: { timer: ringingPayload({ fired_at: new Date(Date.now() - 1_000).toISOString() }) },
});
tap(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.fired_tap_requests = [...requests].sort();
out.after_fired_tap = view();

// ---- tapping a chip that is still COUNTING --------------------------------
await reset();
fetchPlan = () => ({ ok: true, json: async () => timerPayload({ paused_at: new Date().toISOString() }) });
tap(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.running_tap_requests = [...requests];
out.after_running_tap = view();

// ---- the server says it went, by broadcast --------------------------------
await reset();
stack.applyBroadcast({ data: { reason: "archived", timer: timerPayload() } });
out.after_archived_broadcast = view();

process.stdout.write(JSON.stringify(out));
