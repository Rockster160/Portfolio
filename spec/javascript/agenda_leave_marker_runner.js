// Exercises the pure leave-by helpers on the agenda renderer — the logic that
// decides when a departure crosses back onto an earlier day and what the
// synthetic "leave-for" marker looks like. DOM-less, same harness shape as
// agenda_travel_band_runner.js: require the module, print JSON for the spec.

const path = require("path");

const R = require(path.resolve(
  __dirname, "..", "..", "app", "javascript", "src", "agenda_renderer", "item_renderer.js",
));

const DAY = 86400;
const START = 1_750_000_000; // arbitrary fixed epoch; day-deltas use exact 24h steps so TZ doesn't matter

const cases = {
  // leaveEpoch = start - (arrive + travel) * 60; band visible with a real place + a drive.
  derive_visible: R.deriveLeave({
    "start-at": START, "travel-minutes": 12, "arrive-early-minutes": 5, location: "Clinic",
  }),
  // No drive and no buffer → nothing to leave for.
  derive_no_band: R.deriveLeave({
    "start-at": START, "travel-minutes": 0, "arrive-early-minutes": 0, location: "",
  }),

  // Day qualifier — same instant is same day; exact 24h / 48h steps are 1 / 2 days before.
  suffix_same: R.leaveDaySuffix(START, START),
  suffix_prev: R.leaveDaySuffix(START - DAY, START),
  suffix_two:  R.leaveDaySuffix(START - (2 * DAY), START),

  // Marker object: id must equal presentation_attrs["item-id"] (the diffItems keying guard).
  marker: R.makeLeaveMarker(
    { id: 1058, presentation_attrs: { "item-id": "1058", name: "Soccer game", "start-at": START } },
    START - DAY,
    "2025-06-15",
  ),

  is_marker_true:  R.isLeaveMarker({ marker: true }),
  is_marker_attrs: R.isLeaveMarker({ presentation_attrs: { marker: "leave" } }),
  is_marker_false: R.isLeaveMarker({ presentation_attrs: { name: "x" } }),
};

console.log(JSON.stringify({ cases }));
