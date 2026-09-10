// Drives the agenda search modal against a real AgendaStore, and prints
// what landed in the "Upcoming & recent" list, as JSON for
// agenda_search_modal_spec.rb.
//
// search.js is an IIFE wired to real elements, so this builds the
// smallest DOM that answers what it asks: the handful of
// `[data-search-*]` anchors from _search_modal.html.erb, nodes that
// know their class list and children, and a `createElement` the row
// builder can fill. The store underneath is the real one, seeded the
// way the server seeds it — a yearly birthday as a RULE with no
// materialized row, which is the shape that used to be unfindable.

const path = require("path");

const SRC         = path.resolve(__dirname, "..", "..", "app", "javascript", "src");
const AgendaStore = require(path.join(SRC, "agenda_store", "store.js"));
const Recurrence  = require(path.join(SRC, "agenda_store", "recurrence.js"));

// ---- the smallest DOM search.js asks for ---------------------------------
function node(tag) {
  const el = {
    tag,
    className:   "",
    dataset:     {},
    attrs:       {},
    style:       { setProperty() {} },
    children:    [],
    listeners:   {},
    textContent: "",
    classList: {
      add(name)    { el.attrs[`class:${name}`] = true; },
      remove(name) { delete el.attrs[`class:${name}`]; },
      contains(n)  { return !!el.attrs[`class:${n}`]; },
    },
    appendChild(child)   { el.children.push(child); return child; },
    replaceChildren()    { el.children = []; },
    setAttribute(k, v)   { el.attrs[k] = v; },
    getAttribute(k)      { return el.attrs[k] ?? null; },
    addEventListener(name, fn) { el.listeners[name] = fn; },
    querySelector(sel)   { return el.byselector[sel] || null; },
    focus() {},
    byselector: {},
  };
  return el;
}

const modal   = node("div");
const input   = node("input");
const anchors = [
  "[data-search-input]", "[data-search-idle]",
  '[data-search-section="future"]', '[data-search-section="past"]',
  '[data-search-items="future"]', '[data-search-items="past"]',
  '[data-search-empty="future"]', '[data-search-empty="past"]',
  "[data-search-past-status]", ".agenda-search",
];
anchors.forEach((sel) => { modal.byselector[sel] = node("div"); });
modal.byselector["[data-search-input]"] = input;
input.value = "";

const futureList = modal.byselector['[data-search-items="future"]'];
const futureSec  = modal.byselector['[data-search-section="future"]'];

global.document = {
  readyState: "complete",
  getElementById(id) { return id === "agenda-search" ? modal : null; },
  createElement(tag) { return node(tag); },
  addEventListener() {},
};
global.window = {
  AgendaStore,
  AgendaRecurrence: Recurrence,
  localStorage: undefined,
};
// The past-tail fetch is a separate concern; resolve it empty so the
// in-memory pass is what's under test.
global.fetch = () => Promise.resolve({ ok: true, json: () => Promise.resolve({ items: [] }) });

// ---- the store, seeded as the server seeds it ----------------------------
const TZ    = "America/Denver";
const TODAY = "2026-06-22";

AgendaStore.reset();
AgendaStore.applyBootstrap({
  server_ts: 1_700_000_000_000,
  day_key:   TODAY,
  timezone:  TZ,
  items:     [],
  agendas:   [{ id: 32, name: "Birthdays", color: "#e91e63", editable: false }],
  schedules: [{
    id:             149,
    agenda_id:      32,
    name:           "Whisper's Birthday",
    kind:           "event",
    freq:           "yearly",
    interval:       1,
    starts_on:      "2000-10-14",
    until_on:       null,
    all_day:        true,
    start_time:     "00:00",
    excluded_dates: [],
  }],
});

require(path.join(SRC, "agenda", "search.js"));

// ---- type a query, wait out the debounce, read the list ------------------
function textOf(row) {
  return row.children.flatMap((body) => body.children.map((c) => c.textContent));
}

function typeQuery(q) {
  input.value = q;
  input.listeners.input();
  return new Promise((resolve) => setTimeout(resolve, 400));
}

(async () => {
  await typeQuery("whisper");
  const hits = futureList.children.map((row) => ({
    item_id:  row.attrs["data-item-id"],
    readonly: row.getAttribute("data-readonly") !== null,
    lines:    textOf(row),
  }));
  const shown = !futureSec.classList.contains("hidden");

  await typeQuery("dentist");

  process.stdout.write(JSON.stringify({
    hits,
    future_section_shown: shown,
    no_match_rows:        futureList.children.length,
    no_match_section_hidden: futureSec.classList.contains("hidden"),
  }));
})();
