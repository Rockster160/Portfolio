// Runs the browser-side chip algebra over cases supplied on stdin and prints
// the resulting queries, for query_chips_parity_spec.rb to compare against the
// Ruby that renders the same chips server-side.
//
// The module installs document listeners and touches `window` on import, so
// both are stubbed here — this file only exercises the pure algebra behind
// them, which is the half that has to stay identical.
const listeners = {};
globalThis.document = {
  readyState:       "loading",
  addEventListener: (name, fn) => { listeners[name] = fn; },
  querySelectorAll: () => [],
};
globalThis.window = globalThis;

const chunks = [];
process.stdin.on("data", (chunk) => chunks.push(chunk));
process.stdin.on("end", async () => {
  const { cases } = JSON.parse(chunks.join(""));
  await import("../../app/javascript/src/query_chips.js");

  const results = cases.map((c) =>
    globalThis.queryChips.toggledQuery(c.query, c.field, c.value, c.options),
  );

  process.stdout.write(JSON.stringify({ results }));
});
