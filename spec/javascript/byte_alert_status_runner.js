// Feeds alert states through the real label builder and prints the results as
// JSON for byte_alert_status_spec.rb. No DOM — alertStatusLabel is pure, and the
// clock formatter is handed in.
import { alertStatusLabel } from "../../app/javascript/src/pages/byte/alert_status.js";

// Stands in for the app's own formatTime: any ISO in, a readable clock out, and
// "" for a missing one — which is the case that decides half the branches here.
const fmt = (iso) => (iso ? "5:04 PM" : "");

const { alertRowLabel, overflowLabel, MAX_ROWS } = await import(
  "../../app/javascript/src/pages/byte/alert_strip.js"
);

const out = {};

out.open_once = alertStatusLabel({ status: "open", count: 1 });
out.open_no_count = alertStatusLabel({ status: "open" });
out.open_repeated = alertStatusLabel({
  status: "open",
  count: 3,
  last_raised_at: "2026-09-10T17:04:00Z",
}, fmt);
out.open_repeated_no_clock = alertStatusLabel({ status: "open", count: 3 }, fmt);
out.resolved = alertStatusLabel({
  status: "resolved",
  count: 3,
  resolved_at: "2026-09-10T17:12:00Z",
}, fmt);
out.resolved_no_clock = alertStatusLabel({ status: "resolved" }, fmt);
out.dismissed = alertStatusLabel({
  status: "dismissed",
  count: 2,
  resolved_at: "2026-09-10T17:12:00Z",
}, fmt);
out.missing = alertStatusLabel(undefined, fmt);
out.not_an_alert = alertStatusLabel("gate", fmt);
// The count arrives off jsonb and has been a string before now.
out.count_as_string = alertStatusLabel({ status: "open", count: "4" }, fmt);

// ---- the pinned strip -----------------------------------------------------
// One row per open condition, which is also the answer to "can several be
// outstanding at once": they stack, and each is let go of on its own.
out.row = {
  once: alertRowLabel({ body: "The gate is open", count: 1 }),
  repeated: alertRowLabel({ body: "The gate is open", count: 4 }),
  no_count: alertRowLabel({ body: "The gate is open" }),
  blank: alertRowLabel({}),
  nothing: alertRowLabel(undefined),
};

// Two drawn, the rest a count. Scrolling a strip pinned over the pet put a
// native scrollbar down his side, which was worse than the problem.
out.overflow = {
  max_rows: MAX_ROWS,
  none: overflowLabel(1),
  exactly_full: overflowLabel(2),
  one_over: overflowLabel(3),
  many: overflowLabel(9),
  zero: overflowLabel(0),
};

process.stdout.write(JSON.stringify(out, null, 2));
