// Drives AgendaStore.applyBootstrap / applyDelta / applyPage with the
// fixtures from agenda_store_validation_spec.rb and reports back which
// applies were accepted vs rejected. Mirrors the parity_runner pattern.

const path = require("path");

// stub `window` BEFORE requiring the store so its localStorage paths
// no-op without throwing.
global.window = { localStorage: undefined };

const AgendaStore = require(path.resolve(
  __dirname, "..", "..", "app", "javascript", "src", "agenda_store", "store.js",
));

const VALID_BOOTSTRAP = {
  server_ts:        1_700_000_000_000,
  day_key:          "2026-06-22",
  items:            [],
  agendas:          [],
  schedules:        [],
};
const VALID_DELTA = {
  server_ts: 1_700_000_001_000,
  day_key:   "2026-06-22",
  items:     [],
};
const VALID_PAGE = {
  server_ts: 1_700_000_002_000,
  day_key:   "2026-06-22",
  items:     [],
  window:    { from: "2026-06-22", to: "2026-06-29" },
};

const SEED_ITEM = {
  id:           "42",
  name:         "Existing item",
  start_at:     1_700_000_100,
  end_at:       1_700_000_700,
  updated_at:   1_700_000_000,
};

function captureItemSnapshot() {
  return JSON.parse(JSON.stringify(AgendaStore.getState().items));
}

function bootstrapWithSeed() {
  // Cold-bootstrap a known valid payload first so `state.items` carries
  // one row. Subsequent malformed payloads must leave this row intact.
  AgendaStore.reset();
  AgendaStore.applyBootstrap(Object.assign({}, VALID_BOOTSTRAP, {
    items: [SEED_ITEM],
  }));
}

function runCase(kind, payload) {
  bootstrapWithSeed();
  const before = captureItemSnapshot();
  let accepted = false;
  if (kind === "bootstrap") {
    accepted = AgendaStore.applyBootstrap(payload) !== false;
  } else if (kind === "delta") {
    accepted = AgendaStore.applyDelta(payload) !== false;
  } else if (kind === "page") {
    accepted = AgendaStore.applyPage(payload) !== false;
  }
  const after = captureItemSnapshot();
  return {
    accepted:                accepted,
    preserved_existing_item: JSON.stringify(before) === JSON.stringify(after) ||
                              !!after[SEED_ITEM.id],
  };
}

const cases = [
  // BOOTSTRAP: malformed payloads MUST be rejected and local state preserved.
  { name: "bootstrap_rejects_null",        run: () => runCase("bootstrap", null) },
  { name: "bootstrap_rejects_no_server_ts",
    run: () => runCase("bootstrap", Object.assign({}, VALID_BOOTSTRAP, { server_ts: undefined })) },
  { name: "bootstrap_rejects_zero_server_ts",
    run: () => runCase("bootstrap", Object.assign({}, VALID_BOOTSTRAP, { server_ts: 0 })) },
  { name: "bootstrap_rejects_no_day_key",
    run: () => runCase("bootstrap", Object.assign({}, VALID_BOOTSTRAP, { day_key: undefined })) },
  { name: "bootstrap_rejects_malformed_day_key",
    run: () => runCase("bootstrap", Object.assign({}, VALID_BOOTSTRAP, { day_key: "yesterday" })) },
  { name: "bootstrap_rejects_no_items",
    run: () => runCase("bootstrap", Object.assign({}, VALID_BOOTSTRAP, { items: undefined })) },
  { name: "bootstrap_rejects_items_not_array",
    run: () => runCase("bootstrap", Object.assign({}, VALID_BOOTSTRAP, { items: "nope" })) },
  { name: "bootstrap_accepts_valid",
    run: () => runCase("bootstrap", VALID_BOOTSTRAP) },

  // DELTA: equally strict envelope; missing/malformed keys must NOT
  // overwrite any local items.
  { name: "delta_rejects_null",   run: () => runCase("delta", null) },
  { name: "delta_rejects_no_server_ts",
    run: () => runCase("delta", Object.assign({}, VALID_DELTA, { server_ts: undefined })) },
  { name: "delta_rejects_malformed_day_key",
    run: () => runCase("delta", Object.assign({}, VALID_DELTA, { day_key: "2026/06/22" })) },
  { name: "delta_accepts_valid", run: () => runCase("delta", VALID_DELTA) },

  // PAGE: same envelope + items must be array.
  { name: "page_rejects_null",   run: () => runCase("page", null) },
  { name: "page_rejects_no_server_ts",
    run: () => runCase("page", Object.assign({}, VALID_PAGE, { server_ts: null })) },
  { name: "page_rejects_no_items",
    run: () => runCase("page", Object.assign({}, VALID_PAGE, { items: undefined })) },
  { name: "page_accepts_valid",  run: () => runCase("page", VALID_PAGE) },
];

const results = cases.map((c) => ({ name: c.name, result: c.run() }));
process.stdout.write(JSON.stringify({ results }));
