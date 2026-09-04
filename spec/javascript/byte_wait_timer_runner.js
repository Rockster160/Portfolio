// Drives Buddy's timer chips through a WAIT reaching zero and prints what the
// corner of the screen did, as JSON for byte_wait_timer_spec.rb.
//
// Same stubs as byte_timer_swipe_runner: the chips are plain objects that
// remember their listeners, `fetch` is scripted per step, and the document
// records the capture-phase handler the module arms while something is ringing
// — which is the observable difference between a chip that wants a tap and one
// that doesn't.

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

globalThis.window = {
  setInterval: () => 1,
  clearInterval: () => {},
  setTimeout: (fn) => { fn(); return 1; },
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

// The module arms a capture-phase `pointerdown` on the document while anything
// is ringing, and takes it off again when nothing is. That handler IS "you have
// to tap this to make it stop", so its presence is what these cases read.
const docListeners = {};

globalThis.document = {
  createElement: fakeElement,
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

const hero = { dataset: {}, setExpression() {} };
const stack = initBuddyTimers({ container, hero, isBuddyActiveFn: () => true });

// A wait, as the server serializes one: an ordinary running countdown carrying
// the flag Buddy::Timers::WAIT writes when the queue is attached.
function waitPayload(over = {}) {
  return {
    id:            98,
    name:          "Whisper nap sound",
    timer_page_id: 2,
    wait:          true,
    started_at:    new Date(Date.now() - 60_000).toISOString(),
    end_at:        new Date(Date.now() + 240_000).toISOString(),
    duration_ms:   300_000,
    ...over,
  };
}

// A countdown they set themselves. Same shape, no flag.
function plainPayload(over = {}) {
  return {
    id:            94,
    name:          "Pasta",
    timer_page_id: 2,
    started_at:    new Date(Date.now() - 60_000).toISOString(),
    end_at:        new Date(Date.now() + 240_000).toISOString(),
    duration_ms:   300_000,
    ...over,
  };
}

// Past its end_at, which is what makes a chip ring. `fired_at` absent is the
// normal state for the first few seconds — the client rings off the clock, not
// off the server catching up.
const overdue = { end_at: new Date(Date.now() - 3_000).toISOString() };

async function reset(payloads = []) {
  fetchPlan = (url) => ({
    ok:   true,
    json: async () => (url === "/buddy/timers" ? { page_id: 2, timers: payloads } : {}),
  });
  await stack.hydrate();
  Object.keys(docListeners).forEach((k) => delete docListeners[k]);
  requests.length = 0;
}

const view = () => container.children.map((c) => ({
  id:      c.dataset.timerId,
  state:   c.dataset.state,
  icon:    c.children[0]?.textContent ?? null,
  readout: c.children[1]?.textContent ?? null,
  wired:   Object.keys(c.listeners).length > 0,
}));

const out = {};

// ---- a wait that is still counting ----------------------------------------
// It shows. That was never the complaint: the chip is the only sign the delay
// is real.
await reset();
stack.applyBroadcast({ data: { timer: waitPayload() } });
out.counting = view();

// ---- the wait reaches zero ------------------------------------------------
// Prod timer 98, 4 Sep. It rang like a kitchen timer and was tapped away two
// seconds later, with the nap sound already playing.
await reset();
stack.applyBroadcast({ data: { timer: waitPayload(overdue) } });
out.wait_at_zero = view();
out.wait_ack_armed = Object.keys(docListeners);
out.wait_requests = [...requests];

// The server archives it the moment the held step runs, so it leaves on its own.
stack.applyBroadcast({ data: { reason: "archived", timer: waitPayload(overdue) } });
out.after_archive = view();

// ---- an ordinary countdown reaching zero ----------------------------------
// The contrast, and the thing that must not have changed.
await reset();
stack.applyBroadcast({ data: { timer: plainPayload(overdue) } });
out.plain_at_zero = view();
out.plain_ack_armed = Object.keys(docListeners);

// ---- one of each, both due ------------------------------------------------
// A wait sitting in the stack must not silence a real timer next to it.
await reset();
stack.applyBroadcast({ data: { timer: waitPayload(overdue) } });
out.mixed_ack_after_wait = Object.keys(docListeners);
stack.applyBroadcast({ data: { timer: plainPayload(overdue) } });
out.mixed_ack_after_plain = Object.keys(docListeners);
out.mixed = view();

process.stdout.write(JSON.stringify(out));
