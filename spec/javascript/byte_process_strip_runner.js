// Drives the background-process chips through a hydrate, a dismissal, a clear
// and a report that arrives after one, and prints what the strip looked like at
// each step as JSON for byte_process_strip_spec.rb.
//
// The chips are plain objects that remember their listeners, so a dismissal is
// one synthetic click on the chip's × and `fetch` is a script the test sets per
// step.

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
    setAttribute(name, value) { this[name] = value; },
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

// Bundled rather than imported directly, the way byte_timer_cancel_runner does
// it and for the same reason: `processes.js` reaches for "./chip_taps" with no
// extension, which is the house convention and what esbuild resolves for the
// real build, and Node's ESM loader will not.
const { build } = await import("esbuild");
const bundled = await build({
  entryPoints: [new URL("../../app/javascript/src/pages/byte/buddy/processes.js", import.meta.url).pathname],
  bundle:      true,
  format:      "esm",
  write:       false,
  logLevel:    "silent",
});
const { initBuddyProcesses } = await import(
  `data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].text).toString("base64")}`
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
      { label: "Listing", url: "https://boards.greenhouse.io/x/jobs/1" },
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

// Every node under a chip, so a control can be found the way a thumb finds it.
function descendants(node) {
  return node.children.flatMap((child) => [child, ...descendants(child)]);
}

function closeButton(chip) {
  return descendants(chip).find((n) => n.className === "byte-chip-close");
}

// A press and a release in the same place, the way a browser delivers them:
// `pointerdown` on the node, then a `click` carrying where the pointer was.
function press(node, target, { from = [0, 0], to = from } = {}) {
  node.listeners.pointerdown?.({ clientX: from[0], clientY: from[1], target });
  node.listeners.click?.({
    clientX: to[0], clientY: to[1], detail: 1, target,
    stopPropagation() {}, preventDefault() {},
  });
}

function dismiss(chip) {
  const btn = closeButton(chip);
  if (!btn) return false;

  press(btn, btn);
  return true;
}

// A tap that landed on the chip's own body: `closest` finds no link and no
// button above it, which is what the real DOM would answer.
const body = { closest: () => null };

function tap(chip) {
  press(chip, body);
}

// The same press, with the finger travelling on the way: a drag, or a scroll
// that began on a chip.
function drag(chip) {
  press(chip, body, { from: [0, 0], to: [60, 0] });
}

// A click with no press behind it on this element - what arrives after the
// strip re-renders under the finger, and what used to open a tab.
function staleClick(chip) {
  chip.listeners.click?.({ clientX: 0, clientY: 0, detail: 1, target: body });
}

// A tap that landed on something inside the chip that owns it - the pill, say.
// `closest` answers with that node, the way the real DOM would.
function tapOn(chip, node) {
  press(chip, { closest: () => node });
}

// What a chip SAYS, leaving out the links and the × - those are controls, they
// are reported separately, and an assertion about the words should not move
// every time a chip gains one.
function words(node) {
  if (node.tag === "a" || node.tag === "button") return [];
  if (!node.children.length) return node.textContent ? [node.textContent] : [];

  return node.children.flatMap(words);
}

// Every link on a chip, as it would be clicked. The arrow that marks them is
// CSS, so what is asserted here is the label a person reads.
function anchors(node) {
  if (node.tag === "a") return [{ label: node.textContent, href: node.href, target: node.target }];

  return node.children.flatMap(anchors);
}

const view = () => container.children
  .filter((c) => c.className === "byte-process-chip")
  .map((c) => ({
    key:     c.dataset.processKey,
    state:   c.dataset.state,
    stale:   c.dataset.stale ?? null,
    pending: c.dataset.pending ?? null,
    has_url: c.dataset.hasUrl ?? null,
    text:    words(c),
    links:   anchors(c),
    title:   c.title ?? null,
    // The rows a chip actually stacks: the name-and-count line, and the links
    // under it. A third would be the detail row coming back. The bar and the ×
    // are absolutely positioned and cost no height, so neither is one.
    rows:    c.children.filter((n) => !["byte-process-bar", "byte-chip-close"].includes(n.className)).length,
    closes:  Boolean(closeButton(c)),
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
// Drawn, not hidden behind the chip: a tap target nobody knows is a tap target
// is not one.
await reset(payload());
out.links = view()[0].links;

// A tap on a pill is the pill's. The anchor takes it; the chip must not also
// open its own first link in a second tab.
opened.length = 0;
const row = container.children[0].children.find((c) => c.className === "byte-process-links");
tapOn(container.children[0], row.children[1]);
out.tap_on_pill_opened = [...opened];

// ---- where a tap on the body goes -------------------------------------------
// The first link, as a bigger target for the common case of there being one.
await reset(payload());
out.has_url = view()[0].has_url;
tap(container.children[0]);
out.tap_opened = [...opened];

await reset(payload({ links: [] }));
out.no_url = view()[0].has_url;
out.no_links_rows = view()[0].rows;
tap(container.children[0]);
out.tap_without_links = [...opened];

// ---- a gesture that is not a tap --------------------------------------------
// Rocco, 17 Sep: "swiping is now getting triggered as a click ... A drag on it
// should not be counted as a click." And the other half of the same report: the
// × re-renders the strip, so what arrives afterwards lands on a chip that was
// not there when the press began, and that chip opened its link.
await reset(payload());
opened.length = 0;
drag(container.children[0]);
out.after_drag_opened = [...opened];
staleClick(container.children[0]);
out.after_stale_click_opened = [...opened];
tap(container.children[0]);
out.after_tap_opened = [...opened];

// The × is held to the same rule, and a keyboard press (`detail` 0, no pointer
// behind it) is still a press.
await reset(payload());
staleClick(closeButton(container.children[0]));
out.stale_click_requests = [...requests];
closeButton(container.children[0]).listeners.click({
  detail: 0, target: closeButton(container.children[0]),
  stopPropagation() {}, preventDefault() {},
});
await new Promise((r) => setTimeout(r, 0));
out.keyboard_requests = [...requests];

// ---- the busiest a chip ever gets -------------------------------------------
// Waiting on him, four links, a long step and a count: two rows, never three.
await reset(payload({
  state:  "waiting",
  detail: "Referrer Full Name (If Applicable)",
  links:  [1, 2, 3, 4].map((n) => ({ label: `L${n}`, url: `https://example.com/${n}` })),
}));
out.busiest = view()[0];

// ---- the × is on every chip, and is what a dismissal costs ------------------
// One tap, no gesture: the swipe it replaces needed the pointer captured, and
// when that failed the chip was left sitting wherever it had been dragged,
// looking dismissed with nothing ever sent.
await reset(payload());
out.close_label = closeButton(container.children[0])?.textContent ?? null;
out.close_aria = closeButton(container.children[0])?.["aria-label"] ?? null;
// A dismissal is not a trip to the chip's link.
opened.length = 0;

// ---- a dismissal that never lands -------------------------------------------
fetchPlan = () => new Error("offline");
dismiss(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.failed_requests = [...requests];
out.dismiss_opened = [...opened];
out.after_failed_dismiss = view();
pendingTimeouts.forEach((fn) => fn());
out.after_flash_clears = view();

// ---- one that does ----------------------------------------------------------
await reset(payload());
fetchPlan = () => ({ ok: true, json: async () => ({ data: { cleared: true } }) });
dismiss(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.ok_requests = [...requests];
out.after_ok_dismiss = view();

// ---- while it is still in the air -------------------------------------------
await reset(payload());
let release = null;
fetchPlan = () => ({ ok: true, json: () => new Promise((r) => { release = () => r({}); }) });
dismiss(container.children[0]);
await new Promise((r) => setTimeout(r, 0));
out.in_flight = view();
requests.length = 0;
// The × comes off a chip that is already going, so there is nothing to press
// twice and no second DELETE to send.
out.second_dismiss = dismiss(container.children[0]);
out.second_dismiss_requests = [...requests];
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
