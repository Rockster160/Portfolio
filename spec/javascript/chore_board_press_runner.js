// Presses the real chore board and prints what happened, as JSON for
// chore_board_press_spec.rb.
//
// The module owns its own DOM and its own fetches, so both are stubbed and
// recorded rather than performed, the same way byte_drawer_resync_runner.js
// does it: every element is a plain object that remembers what was done to it,
// and `fetch` answers from a script the runner advances between steps so one
// press can fail where the next succeeds.
//
// Clicks go in through the pad's own listener rather than by calling the
// module's internals, because the ROUTING is part of what is being checked -
// the corner buttons sit on top of the disc, so a press on one is also a press
// inside it.

import { initChoreBoard } from "../../app/javascript/src/pages/byte/buddy/chore_board.js";

// ---- the smallest DOM the board uses ----

const camel = (name) =>
  name.replace(/^data-/, "").replace(/-([a-z])/g, (_, c) => c.toUpperCase());

function matches(el, selector) {
  const withValue = selector.match(/^(\w*)\[([\w-]+)="([^"]*)"\]$/);
  if (withValue) {
    const [, tag, attr, value] = withValue;
    if (tag && el.tag !== tag) return false;
    const got = el.attributes[attr] ?? el.dataset[camel(attr)];
    return String(got) === value;
  }
  const bare = selector.match(/^\[([\w-]+)\]$/);
  if (!bare) return false;

  const attr = bare[1];
  return (
    el.attributes[attr] !== undefined || el.dataset[camel(attr)] !== undefined
  );
}

function walk(el, out = []) {
  el.children.forEach((child) => {
    out.push(child);
    walk(child, out);
  });
  return out;
}

function fakeEl(tag) {
  return {
    tag,
    attributes: {},
    dataset: {},
    style: {},
    children: [],
    listeners: {},
    textContent: "",
    className: "",
    title: "",
    hidden: false,
    set innerHTML(v) {
      if (v === "") this.children = [];
    },
    get innerHTML() {
      return "";
    },
    appendChild(child) {
      this.children.push(child);
      return child;
    },
    append(...nodes) {
      nodes.forEach((n) => this.children.push(n));
    },
    setAttribute(name, value) {
      this.attributes[name] = String(value);
    },
    getAttribute(name) {
      return this.attributes[name] ?? null;
    },
    removeAttribute(name) {
      delete this.attributes[name];
    },
    addEventListener(type, fn) {
      this.listeners[type] = fn;
    },
    querySelector(selector) {
      return walk(this).find((el) => matches(el, selector)) || null;
    },
    querySelectorAll(selector) {
      return walk(this).filter((el) => matches(el, selector));
    },
  };
}

const csrf = fakeEl("meta");
csrf.setAttribute("name", "csrf-token");
csrf.setAttribute("content", "tok");

const pad = fakeEl("div");
pad.dataset.boardPad = "";
const empty = fakeEl("p");
empty.dataset.boardEmpty = "";
const root = fakeEl("section");
root.dataset.byteBoard = "";
root.append(pad, empty);

const app = fakeEl("div");
app.dataset.boardTag = "Home";
app.dataset.choresSyncUrl = "/chores/sync";
app.dataset.choreCheerUrl = "/byte/chore_cheer";
app.dataset.boardChores = JSON.stringify([
  {
    id: 1,
    name: "Vacuum",
    short_name: "Vacuum",
    icon: "🧹",
    icon_kind: "emoji",
    tag: "Home",
    target_count: 3,
    progress_count: 0,
    dismissed: false,
    skipped_today: false,
    today_visible: true,
    archived: false,
  },
  {
    id: 2,
    name: "Dishes",
    short_name: "Dishes",
    icon: "🍽",
    icon_kind: "emoji",
    tag: "Home",
    target_count: 1,
    progress_count: 0,
    dismissed: false,
    skipped_today: false,
    today_visible: true,
    archived: false,
  },
]);

globalThis.document = {
  createElement: (tag) => fakeEl(tag),
  createElementNS: (_ns, tag) => fakeEl(tag),
  querySelector: (selector) => (matches(csrf, selector) ? csrf : null),
  addEventListener() {},
  visibilityState: "visible",
};
globalThis.window = {
  localStorage: {
    store: {},
    getItem(k) {
      return this.store[k] ?? null;
    },
    setItem(k, v) {
      this.store[k] = String(v);
    },
  },
  setTimeout: (fn) => fn(),
};

// ---- the network, standing in for the server ----
//
// `world` is what the server believes, and every endpoint moves it the way the
// real one does. It has to be modelled rather than stubbed flat, because
// `/chores/sync` answers the board's own resync - a stub returning nothing
// empties the board on the first skip, which is not a thing the server does.

const requests = [];
let world = [];
// Request lines that should come back a failure, by exact `METHOD /path`.
let failing = new Set();
// Request lines to hold open, so the board can be read MID-flight - which is
// the whole question for the sending state.
let held = new Set();
let release = () => {};

const entry = (id) => world.find((c) => String(c.id) === String(id));

globalThis.fetch = async (url, opts = {}) => {
  const method = opts.method || "GET";
  const line = `${method} ${url}`;
  requests.push(line);

  if (failing.has(line))
    return { ok: false, status: 503, json: async () => ({}) };
  if (held.has(line))
    await new Promise((resolve) => {
      release = resolve;
    });

  const id = (url.match(/items\/(\d+)/) || [])[1];
  const chore = id ? entry(id) : null;
  let body = {};

  if (url === "/chores/sync") {
    body = { chores: world, server_ts: "now" };
  } else if (url === "/byte/chore_cheer") {
    body = { say: "Nice one.", mood: "happy" };
  } else if (url.endsWith("/completion") && method === "POST") {
    chore.progress_count = Math.min(
      chore.progress_count + 1,
      chore.target_count,
    );
    body = { chore };
  } else if (url.endsWith("/dismiss") && method === "POST") {
    chore.dismissed = true;
    body = { chore };
  } else if (url.endsWith("/dismiss") && method === "DELETE") {
    chore.dismissed = false;
    body = { chore };
  } else if (url.endsWith("/skip") && method === "POST") {
    chore.skipped_today = true;
    chore.progress_count = chore.target_count;
    // The real endpoint answers with a COMPLETION, not a chore - which is why
    // skipCycle resyncs instead of folding an answer in.
    body = { skipped_occurrence: true };
  } else if (url.endsWith("/skip") && method === "DELETE") {
    chore.skipped_today = false;
    chore.progress_count = 0;
    body = {};
  }

  return { ok: true, status: 200, json: async () => body };
};

// ---- drive it ----

world = JSON.parse(app.dataset.boardChores).map((c) => ({ ...c }));

const board = initChoreBoard({
  root,
  app,
  conversationIdFn: () => 21,
  sayText: () => {},
});

const click = (selector) => {
  const node = pad.querySelector(selector);
  if (!node) throw new Error(`no node for ${selector}`);
  return pad.listeners.click({
    target: { closest: (sel) => (matches(node, sel) ? node : null) },
  });
};

const cellFor = (id) => pad.querySelector(`[data-board-cell="${id}"]`);
const snapshot = (id) => {
  const cell = cellFor(id);
  return {
    state: cell.dataset.state,
    sending: cell.dataset.sending,
    syncPending: cell.dataset.syncPending,
    ringOffset: cell.querySelector("[data-board-ring]").style.strokeDashoffset,
    count: cell.querySelector("[data-board-count]").textContent,
  };
};

const out = {};

// What an untouched chore offers: both skips, no undo.
out.controls_open = {
  skip: cellFor(1).querySelector("[data-board-skip-day]").hidden,
  cycle: cellFor(1).querySelector("[data-board-skip-cycle]").hidden,
  undo: cellFor(1).querySelector("[data-board-undo]").hidden,
};

// The ring has to have moved before the answer arrives. Captured by holding
// the request open and reading the cell while it is still in the air.
held = new Set(["POST /chores/items/1/completion"]);
const inFlight = click('[data-board-complete="1"]');
out.mid_flight = snapshot(1);
release();
held = new Set();
await inFlight;
out.after_answer = snapshot(1);

// Two more presses on a 3-target chore, back to back, neither waited on. The
// first answer back must not clear the other's in-flight state, and a disc
// that stopped taking presses would drop the second.
requests.length = 0;
const burst = [
  click('[data-board-complete="1"]'),
  click('[data-board-complete="1"]'),
];
out.burst_mid = snapshot(1);
await Promise.all(burst);
out.burst_after = snapshot(1);
out.burst_requests = requests.filter((r) => r.endsWith("/completion")).length;
out.controls_done = {
  skip: cellFor(1).querySelector("[data-board-skip-day]").hidden,
  undo: cellFor(1).querySelector("[data-board-undo]").hidden,
};

// A press that FAILS keeps its prediction and says so with the dot.
requests.length = 0;
failing = new Set(["POST /chores/items/2/dismiss"]);
await click('[data-board-skip-day="2"]');
out.failed = snapshot(2);
out.server_never_got_it = entry(2).dismissed;

// ...and is tried again when the socket comes back.
failing = new Set();
requests.length = 0;
await board.onReconnect();
out.retry_requests = requests.filter((r) => r.includes("/dismiss"));
out.after_retry = snapshot(2);
out.server_has_it_now = entry(2).dismissed;

// A press on a chore already put away does nothing - its corner carries Undo,
// which is the only thing a press on a grey circle could sensibly mean.
requests.length = 0;
await click('[data-board-complete="2"]');
out.press_while_away = requests.length;
out.controls_away = {
  skip: cellFor(2).querySelector("[data-board-skip-day]").hidden,
  undo: cellFor(2).querySelector("[data-board-undo]").hidden,
};

// Undo puts it back, by whichever call put it away.
await click('[data-board-undo="2"]');
out.after_undo = snapshot(2);

// The guard on the splice: a successful press must not take an unrelated
// remembered failure down with it.
failing = new Set(["POST /chores/items/2/dismiss"]);
await click('[data-board-skip-day="2"]');
out.failure_before = cellFor(2).dataset.syncPending;
failing = new Set();
await click('[data-board-complete="1"]');
out.failure_survived_other_press = cellFor(2).dataset.syncPending;

process.stdout.write(JSON.stringify(out, null, 2));
