// Drives the background-process chips through a hydrate, a swipe, a clear and
// a report that arrives after one, and prints what the strip looked like at
// each step as JSON for byte_process_strip_spec.rb.
//
// Same shape as byte_timer_swipe_runner.js, and for the same reason: the chips
// are plain objects that remember their listeners, so a swipe is three
// synthetic pointer events and `fetch` is a script the test sets per step.

// The module warns on a failed clear, which is correct and which this file
// causes on purpose.
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

const pendingTimeouts = [];
const opened = [];

globalThis.window = {
  setInterval: () => 1,
  clearInterval: () => {},
  setTimeout: (fn) => {
    pendingTimeouts.push(fn);
    return pendingTimeouts.length;
  },
  open: (url) => opened.push(url),
};

function fakeElement(tag) {
  return {
    tag,
    className:   "",
    textContent: "",
    dataset:     {},
    listeners:   {},
    children:    [],
    style:       { setProperty(name, value) { this[name] = value; } },
    appendChild(child) { this.children.push(child); },
    addEventListener(name, fn) { this.listeners[name] = fn; },
    setPointerCapture() {},
    releasePointerCapture() {},
    hasPointerCapture() { return false; },
  };
}

globalThis.document = {
  createElement: fakeElement,
  querySelector: () => ({ getAttribute: () => "csrf" }),
};

const container = {
  hidden:   false,
  children: [],
  set innerHTML(_v) { this.children = []; },
  get innerHTML() { return ""; },
  appendChild(child) { this.children.push(child); },
};

const { initBuddyProcesses } = await import(
  "../../app/javascript/src/pages/byte/buddy/processes.js"
);

const strip = initBuddyProcesses({ container, isBuddyActiveFn: () => true });

function payload(over = {}) {
  return {
    id:           7,
    key:          "jobhunt:line",
    name:         "Preparing",
    state:        "running",
    detail:       "Fieldwire - writing the letter",
    current:      3,
    total:        13,
    links:        [
      { label: "Posting", url: "https://boards.greenhouse.io/x/jobs/1" },
      { label: "Line", url: "http://localhost:8790/line" },
    ],
    started_at:   new Date(Date.now() - 60_000).toISOString(),
    heartbeat_at: new Date().toISOString(),
    ...over,
  };
}

async function reset(...rows) {
  pendingTimeouts.length = 0;
  opened.length = 0;
  fetchPlan = () => ({ ok: true, json: async () => ({ data: { processes: rows } }) });
  await strip.hydrate();
  requests.length = 0;
}

function swipe(chip) {
  chip.listeners.pointerdown({ clientX: 0, pointerId: 1 });
  chip.listeners.pointermove({ clientX: 130, pointerId: 1 });
  chip.listeners.pointerup({ clientX: 130, pointerId: 1 });
}

function tap(chip) {
  chip.listeners.pointerdown({ clientX: 0, pointerId: 1 });
  chip.listeners.pointerup({ clientX: 0, pointerId: 1 });
}

// The chip's own words, in order, however deeply nested. The link pills are
// left out on purpose - they are reported separately, so an assertion about
// what a chip SAYS does not move every time one gains a link.
function words(node) {
  if (node.tag === "a") return [];
  if (!node.children.length) return node.textContent ? [node.textContent] : [];

  return node.children.flatMap(words);
}

// Every anchor on a chip, however deeply nested, as it would be clicked.
function anchors(node) {
  if (node.tag === "a") return [{ label: node.textContent, href: node.href, target: node.target }];

  return node.children.flatMap(anchors);
}

const view = () => container.children.map((c) => ({
  key:      c.dataset.processKey,
  state:    c.dataset.state,
  stale:    c.dataset.stale ?? null,
  pending:  c.dataset.pending ?? null,
  has_url:  c.dataset.hasUrl ?? null,
  text:     words(c),
  links:    anchors(c),
  wired:    Object.keys(c.listeners).length > 0,
}));

const out = {};

// ---- what a running process looks like ------------------------------------
await reset(payload());
out.running = view();

// Nothing running is nothing to show. An empty strip must not sit in the
// corner of the hero as an empty box.
await reset();
out.empty = { shown: container.children.length, hidden: container.hidden };

// ---- the count, when only half of it is known -----------------------------
await reset(payload({ total: null }));
out.count_without_total = view()[0].text;
await reset(payload({ current: null, total: null }));
out.no_count = view()[0].text;

// ---- gone quiet ------------------------------------------------------------
// Nothing heard for twenty minutes. The count it is showing is frozen, so the
// chip has to stop reading as work still going on.
await reset(payload({ heartbeat_at: new Date(Date.now() - 20 * 60_000).toISOString() }));
out.stale = view();

// Waiting is stalled on purpose. It is not the same thing as having died.
await reset(payload({
  state:        "waiting",
  detail:       "8 questions waiting on you",
  heartbeat_at: new Date(Date.now() - 20 * 60_000).toISOString(),
}));
out.waiting = view();

// ---- how much of the hero it takes up ---------------------------------------
// It sits over Buddy. Three chips, then a line saying what was left out - a
// strip that showed three of eight and said nothing would read as three.
await reset(
  payload({ key: "a", state: "waiting" }),
  payload({ key: "b" }),
  payload({ key: "c" }),
  payload({ key: "d" }),
  payload({ key: "e" }),
);
out.capped = {
  chips: container.children.filter((c) => c.className === "byte-process-chip").length,
  more:  container.children.filter((c) => c.className === "byte-process-more").map((c) => c.textContent),
};

// Under the cap there is nothing to say, so nothing is said.
await reset(payload({ key: "a" }), payload({ key: "b" }));
out.uncapped_more = container.children.filter((c) => c.className === "byte-process-more").length;

// ---- the links --------------------------------------------------------------
await reset(payload());
out.links = view()[0].links;

// A third row costs about as much height as the other two together, so a
// running chip with one link does without it and lets its body be the target.
await reset(payload({ links: [{ label: "Line", url: "http://localhost:8790/line" }] }));
out.one_link_running = view()[0];

// Stopped and waiting on him: the links ARE the point, so they are drawn.
await reset(payload({
  state: "waiting",
  links: [{ label: "Line", url: "http://localhost:8790/line" }],
}));
out.one_link_waiting = view()[0];

// A tap on a pill must never start the chip's swipe, or reaching for the job
// would ask for the chip to be cleared.
await reset(payload());
let stopped = 0;
const pill = container.children[0].children.find((c) => c.className === "byte-process-links");
pill.children[0].listeners.pointerdown({ stopPropagation: () => { stopped += 1; } });
out.pill_stops_the_swipe = stopped;

// ---- a tap on the body ------------------------------------------------------
// One link means the whole chip is a shortcut to it. Several and the body has
// no single right answer, so only the pills are tappable.
await reset(payload({ links: [{ label: "Line", url: "http://localhost:8790/line" }] }));
out.one_link_has_url = view()[0].has_url;
tap(container.children[0]);
out.tap_opened = [...opened];

await reset(payload());
out.two_links_has_url = view()[0].has_url;
tap(container.children[0]);
out.tap_with_two_links = [...opened];

await reset(payload({ links: [] }));
tap(container.children[0]);
out.tap_without_links = [...opened];

// ---- a swipe that never lands ----------------------------------------------
await reset(payload());
fetchPlan = () => new Error("offline");
swipe(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.failed_requests = [...requests];
out.after_failed_swipe = view();
pendingTimeouts.forEach((fn) => fn());
out.after_flash_clears = view();

// ---- a swipe that does ------------------------------------------------------
await reset(payload());
fetchPlan = () => ({ ok: true, json: async () => ({ data: { cleared: true } }) });
swipe(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.ok_requests = [...requests];
out.after_ok_swipe = view();

// ---- while it is still in the air -------------------------------------------
await reset(payload());
let release = null;
fetchPlan = () => ({ ok: true, json: () => new Promise((r) => { release = () => r({}); }) });
swipe(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.in_flight = view();
requests.length = 0;
if (container.children[0]?.listeners?.pointerdown) swipe(container.children[0]);
out.second_swipe_requests = [...requests];
release?.();
await new Promise((r) => setTimeout(r, 0));

// ---- clearing says "stop showing me this", not "stop doing that" ------------
// The work carries on, and its next report has to put the chip back - otherwise
// a stale swipe wins a race it never knew it was in and the rest of a
// twenty-minute run reports into nothing.
await reset(payload());
strip.applyBroadcast({ data: { reason: "cleared", process: payload({ state: "finished" }) } });
out.after_cleared_broadcast = view();
strip.applyBroadcast({ data: { reason: "reported", process: payload({ current: 4 }) } });
out.after_report_following_clear = view();

console.log(JSON.stringify(out));
