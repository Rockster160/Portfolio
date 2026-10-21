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

import esbuild from "esbuild";
import { fileURLToPath } from "url";

// Bundled rather than imported, like deploy_reload_runner: the board's modules
// use extensionless specifiers that esbuild resolves and node does not. The
// socket consumer is stubbed so the board's subscriptions go nowhere.
const stubConsumer = {
  name: "stub-consumer",
  setup(build) {
    build.onResolve({ filter: /channels\/consumer$/ }, () => ({
      path: "consumer-stub",
      namespace: "stub",
    }));
    build.onLoad({ filter: /.*/, namespace: "stub" }, () => ({
      contents: `
        export default {
          connection: { reopen: () => {} },
          subscriptions: {
            create: (_params, mixin) => {
              globalThis.__socket = mixin;
              return { perform: () => {} };
            },
          },
        };
      `,
      loader: "js",
    }));
  },
};

const built = await esbuild.build({
  entryPoints: [
    fileURLToPath(new URL("../../app/javascript/src/pages/byte/buddy/chore_board.js", import.meta.url)),
  ],
  bundle: true,
  format: "esm",
  write: false,
  plugins: [stubConsumer],
  logLevel: "silent",
});

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
  const klass = selector.match(/^\.([\w-]+)$/);
  if (klass) return String(el.className || "").split(/\s+/).includes(klass[1]);
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

// Detach a node from wherever it is, so moving one doesn't leave a copy.
function detach(node) {
  const parent = node.parentNode;
  if (!parent) return;
  const at = parent.children.indexOf(node);
  if (at >= 0) parent.children.splice(at, 1);
  node.parentNode = null;
}

function fakeEl(tag) {
  return {
    tag,
    parentNode: null,
    attributes: {},
    dataset: {},
    style: { setProperty() {}, removeProperty() {} },
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
    get firstChild() {
      return this.children[0] || null;
    },
    get nextSibling() {
      const siblings = this.parentNode?.children || [];
      return siblings[siblings.indexOf(this) + 1] || null;
    },
    appendChild(child) {
      detach(child);
      this.children.push(child);
      child.parentNode = this;
      return child;
    },
    append(...nodes) {
      nodes.forEach((n) => this.appendChild(n));
    },
    insertBefore(node, ref) {
      detach(node);
      const at = ref ? this.children.indexOf(ref) : -1;
      this.children.splice(at < 0 ? this.children.length : at, 0, node);
      node.parentNode = this;
      return node;
    },
    remove() {
      detach(this);
    },
    replaceWith(node) {
      const parent = this.parentNode;
      if (!parent) return;
      detach(node);
      parent.children[parent.children.indexOf(this)] = node;
      node.parentNode = parent;
      this.parentNode = null;
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
app.dataset.boardTags = JSON.stringify(["Home"]);
app.dataset.boardItemsUrl = "/byte/board/items";
app.dataset.choreCheerUrl = "/byte/chore_cheer";
app.dataset.boardItems = JSON.stringify([
  {
    id: 1,
    name: "Vacuum",
    short_name: "Vacuum",
    icon: "🧹",
    icon_kind: "emoji",
    tags: ["Home"],
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
    tags: ["Home"],
    target_count: 1,
    progress_count: 0,
    dismissed: false,
    skipped_today: false,
    today_visible: true,
    archived: false,
  },
  // Pressed with no connection.
  {
    id: 4,
    name: "Plants",
    short_name: "Plants",
    icon: "🪴",
    icon_kind: "emoji",
    tags: ["Home"],
    target_count: 1,
    progress_count: 0,
    dismissed: false,
    skipped_today: false,
    today_visible: true,
    archived: false,
  },
  // A trigger (routine) in the same group: tap to fire, no occurrence to settle.
  {
    id: 3,
    kind: "trigger",
    name: "Focus mode",
    short_name: "Focus mode",
    icon: null,
    icon_kind: "empty",
  },
  // A credit button: a press completes chore 1 crediting someone, and answers
  // with the fresh chore so that chore's own circle flips to done.
  {
    id: 7,
    kind: "credit",
    name: "Vacuum, by mate",
    short_name: "Vacuum, by mate",
    color: "#16A34A",
    icon: null,
    icon_kind: "empty",
    chore_id: 1,
    credit_user_id: 99,
  },
  // A task button: runs a Jil task, answered with an empty 200.
  {
    id: 8,
    kind: "task",
    name: "Fed",
    short_name: "Fed",
    icon: null,
    icon_kind: "empty",
  },
]);

const laterTimers = [];

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
  // Anything short runs at once; a long wait (a checked list item's time to
  // leave) is kept for the runner to run when it says time has passed.
  setTimeout: (fn, ms = 0) => (ms > 1000 ? laterTimers.push(fn) : fn()),
  clearTimeout: () => {},
  addEventListener() {},
};
// The socket monitor names the page it subscribes from as it loads.
globalThis.window.location = { pathname: "/byte", search: "" };

const { initChoreBoard, listSummary } = await import(
  "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64")
);
// Only the trigger flash reaches for it, and only to scope a selector.
globalThis.CSS = { escape: (s) => s };

// ---- the network, standing in for the server ----
//
// `world` is what the server believes, and every endpoint moves it the way the
// real one does. It has to be modelled rather than stubbed flat, because
// `/byte/board/items` answers the board's own resync - a stub returning nothing
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

  if (url.startsWith("/byte/board/list_items/")) {
    // Checked off (or back): answers with the item and when it leaves.
    chore.checked = method === "POST";
    const leaves = chore.leaves_in_ms ?? 3600000;
    chore.clears_at = chore.checked ? new Date(Date.now() + leaves).toISOString() : null;
    body = { item: chore };
  } else if (url.startsWith("/byte/board/items")) {
    // The board's own resync endpoint - chores AND triggers of the group. This
    // suite drives only chores, so world is the whole answer.
    body = { items: world };
  } else if (url === "/byte/chore_cheer") {
    body = { say: "Nice one.", mood: "happy" };
  } else if (url.endsWith("/run") && method === "POST") {
    // Firing a trigger (routine). Nothing to fold back - the flash is the
    // receipt.
    body = {};
  } else if (url.startsWith("/byte/board/tasks/") && method === "POST") {
    // A task button press: the server answers a bare `head :ok`, no body.
    return { ok: true, status: 200, text: async () => "" };
  } else if (url.endsWith("/press") && method === "POST") {
    // A credit button press completes its chore (1 here) crediting someone, and
    // answers with the fresh chore so its circle updates.
    const c = entry(1);
    c.progress_count = Math.min(c.progress_count + 1, c.target_count);
    body = { chore: c, credited: "mate" };
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

  return { ok: true, status: 200, text: async () => JSON.stringify(body) };
};

// ---- drive it ----

world = JSON.parse(app.dataset.boardItems).map((c) => ({ ...c }));

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

// A press still waiting on the server is kept while another one goes out
// and lands past it.
failing = new Set(["POST /chores/items/2/dismiss"]);
await click('[data-board-skip-day="2"]');
out.failure_before = cellFor(2).dataset.syncPending;
await click('[data-board-complete="1"]');
out.failure_survived_other_press = cellFor(2).dataset.syncPending;
out.other_press_landed = requests.includes("POST /chores/items/1/completion");
failing = new Set();
await board.onReconnect();

// ---- no connection at all ----
//
// A press with nothing to send it over is kept, shown, and goes out with the
// time it was pressed once the server can be reached.
const fetchOnline = globalThis.fetch;
globalThis.fetch = async (url, opts = {}) => {
  requests.push(`${opts.method || "GET"} ${url} (offline)`);
  throw new TypeError("Failed to fetch");
};
requests.length = 0;
await click('[data-board-complete="4"]');
out.offline_press = {
  ...snapshot(4),
  kept: JSON.parse(window.localStorage.getItem("byte.board.queue.21") || "[]").map((e) => e.kind),
  pressed_at: JSON.parse(window.localStorage.getItem("byte.board.queue.21") || "[]")[0]?.requests?.[0]?.body?.client_completed_at != null,
};
// A resync while still offline leaves the board as it was rather than empty.
await board.resync();
out.offline_resync_cells = pad.children.length;
globalThis.fetch = fetchOnline;
await board.onReconnect();
out.back_online = { ...snapshot(4), server: entry(4).progress_count };

// ---- a trigger: tap to fire, not tick to finish ----
//
// A trigger circle has no ring, no count and no skip/undo corners - nothing to
// settle - so none of them render. A press fires the routine and nothing else:
// the run endpoint, and no chore endpoint.
const triggerCell = cellFor(3);
out.trigger_controls = {
  ring: triggerCell.querySelector("[data-board-ring]") === null,
  count: triggerCell.querySelector("[data-board-count]") === null,
  skip: triggerCell.querySelector("[data-board-skip-day]") === null,
  undo: triggerCell.querySelector("[data-board-undo]") === null,
  state: triggerCell.dataset.state,
};

requests.length = 0;
await click('[data-board-complete="3"]');
out.fire_requests = [...requests];
out.fire_hit_no_chore_endpoint = requests.every((r) => !r.includes("/chores/"));

// ---- a credit button: completes a chore crediting someone ----
//
// Stateless like a trigger (no ring/skip), but a press hits the credit endpoint
// and nothing on /chores/, and it folds the fresh chore back in.
const creditCell = cellFor(7);
out.credit_controls = {
  ring: creditCell.querySelector("[data-board-ring]") === null,
  skip: creditCell.querySelector("[data-board-skip-day]") === null,
  state: creditCell.dataset.state,
};

requests.length = 0;
await click('[data-board-complete="7"]');
out.credit_requests = requests;
out.credit_hit_no_chore_endpoint = requests.every((r) => !r.includes("/chores/"));

// A task press answered with an empty 200 landed: no amber dot, and nothing
// kept back to run the task a second time.
const beforeTask = requests.length;
await click('[data-board-complete="8"]');
out.task_press = {
  syncPending: cellFor(8).dataset.syncPending,
  requests: requests.slice(beforeTask),
};

// ---- the set changing under the screen ----
//
// A new button arriving (and one going) moves cells in and out around the
// ones already there; nothing standing is torn down and rebuilt.
const standing = cellFor(1);
const keys = () => pad.children.map((c) => c.dataset.boardKey);
world.splice(world.findIndex((c) => c.kind === "task"), 0, {
  id: 9, kind: "task", name: "Nap", short_name: "Nap", icon: "😴", icon_kind: "emoji",
});
await board.resync();
out.set_change = {
  same_node: cellFor(1) === standing,
  keys: keys(),
};
world = world.filter((c) => !(c.kind === "task" && c.id === 9));
await board.resync();
out.set_change.after_removal = keys();
out.set_change.same_node_after_removal = cellFor(1) === standing;

// ---- a task button wearing its tile ----
//
// Read the way the list pages read it: `text` goes ON the disc, the name under
// it stays the button's own, and an `icon` takes the text's place.
world.push({ id: 10, kind: "task", name: "Garage", short_name: "Garage", icon: "🚗", icon_kind: "emoji", monitor: "garage" });
await board.resync();
const tile = (data) => globalThis.__socket.received({ id: "garage", data });
const face = () => {
  const glyph = cellFor(10).querySelector(".byte-board-icon");
  return {
    title: cellFor(10).querySelector(".byte-board-title")?.textContent,
    text: glyph.textContent,
    words: glyph.dataset.words,
    fontSize: glyph.style.fontSize || null,
    img: glyph.children[0]?.src || null,
  };
};
tile({ text: "Close Garage", fontSize: 20 });
out.tile_text = face();
tile({ text: "[stack 🔔💤]" });
out.tile_stack = { ...face(), stacked: cellFor(10).querySelector(".byte-board-icon").children[0]?.className };
tile({ text: "Opening...", icon: "<svg viewBox='0 0 10 10'></svg>", label: "Garage door" });
out.tile_icon = face();

// ---- a connected list's items ----
//
// Pressed to check off: the ring fills before the answer, Undo appears, a
// second press sends nothing, and the circle leaves when its time is up.
world.push(
  { id: 11, kind: "list", name: "Chairs", short_name: "Chairs", icon: null, icon_kind: "empty", priority: "high", rank: 5, checked: false, clears_at: null },
  { id: 12, kind: "list", name: "🔑 Keys", short_name: "Keys", icon: "🔑", icon_kind: "emoji", priority: "normal", rank: 4, checked: false, clears_at: null, leaves_in_ms: 5000 },
);
await board.resync();
const listCell = (id) => {
  const cell = cellFor(id);
  return {
    state: cell.dataset.state,
    priority: cell.dataset.priority,
    sending: cell.dataset.sending,
    ring: cell.querySelector("[data-board-ring]").style.strokeDashoffset,
    undoHidden: cell.querySelector("[data-board-list-undo]").hidden,
    face: cell.querySelector(".byte-board-icon").textContent,
    title: cell.querySelector(".byte-board-title").textContent,
  };
};
out.list_open = { chairs: listCell(11), keys: listCell(12) };

held = new Set(["POST /byte/board/list_items/11/check"]);
const listPress = click('[data-board-complete="11"]');
out.list_mid = listCell(11);
held = new Set();
release();
await listPress;
out.list_after = listCell(11);

const beforeAgain = requests.length;
await click('[data-board-complete="11"]');
out.list_pressed_again = requests.length - beforeAgain;

await click('[data-board-list-undo="11"]');
out.list_undone = { ...listCell(11), request: requests[requests.length - 1] };

// Keys leaves five seconds after it's checked: still there until the timer
// the board set for it runs, then gone.
await click('[data-board-complete="12"]');
out.list_before_leaving = !!cellFor(12);
const realNow = Date.now;
Date.now = () => realNow() + 6000;
laterTimers.splice(0).forEach((fn) => fn());
Date.now = realNow;
out.list_left = !cellFor(12);

// How long checked items stay, as the settings show it.
const stays = [30, 300, 3600, 7200, 90, 0, "end_of_day"];
out.clear_after = {
  summaries: stays.map((clear_after) => listSummary({ list_id: 1, list_name: "GO", clear_after })),
  none: listSummary({}),
};

process.stdout.write(JSON.stringify(out, null, 2));
