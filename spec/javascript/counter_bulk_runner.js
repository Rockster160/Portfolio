// Drives the counter bulk-adjust sheet against a stub DOM and prints what
// the sum line said at each step, as JSON for counter_bulk_spec.rb.
//
// The sheet's whole job is arithmetic the person can check before they
// commit to it, so what's recorded here is the text of the preview and
// the single increment call that leaves at the end.

const modulePath = new URL(
  "../../app/javascript/src/pages/timers/counter_bulk_modal.js",
  import.meta.url,
);
const { setupCounterBulkModal, parseAmounts } = await import(modulePath);

globalThis.requestAnimationFrame = (fn) => fn();

function el(selector) {
  return {
    selector,
    value:       "",
    textContent: "",
    disabled:    false,
    listeners:   {},
    classes:     new Set(),
    classList:   {
      add(c)    { this.owner.classes.add(c); },
      remove(c) { this.owner.classes.delete(c); },
    },
    addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); },
    dispatch(type, event = {}) {
      (this.listeners[type] || []).forEach((fn) => fn({ preventDefault() {}, ...event }));
    },
    focus() {},
  };
}

function wire(node) {
  node.classList.owner = node;
  return node;
}

const nodes = {};
[
  "[data-timers-bulk-form]",
  "[data-timers-bulk-title]",
  "[data-timers-bulk-sum]",
  "[data-timers-bulk-terms]",
  "[data-timers-bulk-input]",
  "[data-timers-bulk-apply]",
].forEach((sel) => { nodes[sel] = wire(el(sel)); });

let open = false;
const dialog = {
  querySelector:    (sel) => nodes[sel] || null,
  querySelectorAll: () => [],
  showModal() { open = true; },
  close()     { open = false; },
};
const root = { querySelector: (sel) => (sel === "[data-timers-bulk-modal]" ? dialog : null) };

const timers = new Map([
  [7, { id: 7, kind: "counter", name: "Rocco", value: 43, step: 3 }],
  [8, { id: 8, kind: "countdown", name: "Tea" }],
]);
const increments = [];
const store = { timers };
const actions = { increment: async (id, by, amount) => increments.push({ id, by, amount }) };

const sheet = setupCounterBulkModal({ root, store, actions });

const form  = nodes["[data-timers-bulk-form]"];
const sum   = nodes["[data-timers-bulk-sum]"];
const terms = nodes["[data-timers-bulk-terms]"];
const input = nodes["[data-timers-bulk-input]"];
const apply = nodes["[data-timers-bulk-apply]"];
const title = nodes["[data-timers-bulk-title]"];

function type(text) {
  input.value = text;
  input.dispatch("input");
  return { sum: sum.textContent, terms: terms.textContent, applyDisabled: apply.disabled };
}

const out = {};

sheet.open(7, 1);
out.opened_title = title.textContent;
out.opened_empty = { sum: sum.textContent, idle: sum.classes.has("is-idle"), applyDisabled: apply.disabled };
out.single = type("18");
out.several = type("5, 8, -2");
out.newlines = type("5\n8\n-2");
out.all_negative = type("-5 -8");
out.nets_to_zero = type("5 -5");
out.junk = type("hello");

// Applying is one increment carrying the total as a raw amount — never a
// step count, and never one call per number.
type("5 8 -2");
form.dispatch("submit");
await new Promise((r) => setTimeout(r, 0));
out.applied = increments.slice();
out.closed_on_apply = !open;

// Held on the − button: what you type is subtracted, unsigned.
sheet.open(7, -1);
out.minus_title = title.textContent;
out.minus_single = type("18");
out.minus_with_negative = type("18 -6");
increments.length = 0;
form.dispatch("submit");
await new Promise((r) => setTimeout(r, 0));
out.minus_applied = increments.slice();

// A countdown has no value to adjust; the sheet must not open on one.
open = false;
sheet.open(8, 1);
out.opened_on_countdown = open;

out.parse = {
  spaces:   parseAmounts("5 8 2"),
  commas:   parseAmounts("5, 8, 2"),
  mixed:    parseAmounts("5\n8, -2"),
  run_on:   parseAmounts("5-2"),
  words:    parseAmounts("add 5 please"),
  empty:    parseAmounts(""),
};

console.log(JSON.stringify(out));
