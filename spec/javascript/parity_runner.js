// Reads a fixtures JSON from stdin, runs the JS recurrence expander
// against each fixture's schedule + date_range, and writes a results
// JSON to stdout. Used by recurrence_parity_spec.rb — Ruby produces
// the "expected" matches itself, then asks Node for the JS "actual"
// matches; the spec compares both sides for parity. Any drift between
// the two implementations fails the test.

const path = require("path");
const fs = require("fs");
const Recurrence = require(path.resolve(__dirname, "..", "..", "app", "javascript", "src", "agenda_store", "recurrence.js"));

let raw = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (chunk) => { raw += chunk; });
process.stdin.on("end", () => {
  try {
    const payload = JSON.parse(raw);
    const results = payload.cases.map((c) => ({
      name:    c.name,
      matches: Recurrence.expand(c.schedule, c.from, c.to),
    }));
    process.stdout.write(JSON.stringify({ results }));
  } catch (err) {
    process.stderr.write(`parity_runner error: ${err && err.stack ? err.stack : err}\n`);
    process.exit(1);
  }
});
