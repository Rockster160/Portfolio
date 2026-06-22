// Locks travel-metadata inheritance for recurring phantoms. Mirrors
// `AgendaSchedule#build_phantom` on the Ruby side: a phantom item
// inherits the schedule's `metadata["travel_minutes"]` (top-level
// legacy shape) AND the nested `metadata.travel.*` hash so the cal
// renderer reads the same travel-band data on phantoms that it does
// on materialized rows. The regression this guards: TMS recurring
// schedule's materialized row (today) showed a 23-min travel band,
// but every Friday-and-onward phantom rendered a bandless tile
// because `buildPhantom` had hardcoded "travel-minutes": 0.

const path = require("path");

const Recurrence = require(path.resolve(
  __dirname, "..", "..", "app", "javascript", "src", "agenda_store", "recurrence.js",
));

function localEpoch(dateISO, timeHHMM) {
  const [h, m] = String(timeHHMM || "00:00").split(":").map(Number);
  return Math.floor(Date.UTC(
    Number(dateISO.slice(0, 4)),
    Number(dateISO.slice(5, 7)) - 1,
    Number(dateISO.slice(8, 10)),
    h || 0, m || 0, 0,
  ) / 1000);
}

const agenda = { id: 1, source: "local", color: "#0160FF", name: "Personal" };
const cases = [];

// --- Case 1: legacy shape (top-level travel_minutes only) ----------
// Most older schedules carry this — the resolver wrote travel_minutes
// in flat form before the nested `travel` hash was introduced.
{
  const sched = {
    id: 112, agenda_id: 1, kind: "event", name: "TMS",
    start_time: "08:00", duration_minutes: 30, all_day: false,
    starts_on: "2026-06-22",
    metadata: { travel_minutes: 23, travel_location: "<addr>" },
  };
  const phantom = Recurrence.buildPhantom(sched, "2026-06-26", { localEpoch, agenda });
  cases.push({
    name: "legacy_travel_minutes_only",
    attrs: phantom.presentation_attrs,
  });
}

// --- Case 2: full nested travel hash (modern shape) ----------------
// Schedules that have been through the travel-chain resolver carry the
// full nested shape. Every nested field must propagate.
{
  const sched = {
    id: 113, agenda_id: 1, kind: "event", name: "Costco run",
    start_time: "10:00", duration_minutes: 60, all_day: false,
    starts_on: "2026-06-22",
    arrive_early_minutes: 5,
    metadata: {
      travel_minutes: 15,
      travel: {
        location_address:     "13123 S 5600 W, Herriman, UT 84096",
        travel_from:          "Home St",
        travel_from_kind:     "home",
        chain_predecessor_id: 99,
        chain_successor_id:   100,
        chain_prev_end_at:    1234,
        leave_at:             5678,
      },
    },
  };
  const phantom = Recurrence.buildPhantom(sched, "2026-06-29", { localEpoch, agenda });
  cases.push({
    name: "full_travel_chain",
    attrs: phantom.presentation_attrs,
  });
}

// --- Case 3: schedule with no metadata at all (defaults to zero) ---
// Guards against the inheritance accidentally turning into a hard-
// fail when metadata is missing — most newly-created schedules look
// like this until a resolver run lands.
{
  const sched = {
    id: 114, agenda_id: 1, kind: "task", name: "Standup",
    start_time: "09:00", duration_minutes: 15, all_day: false,
    starts_on: "2026-06-22",
  };
  const phantom = Recurrence.buildPhantom(sched, "2026-06-23", { localEpoch, agenda });
  cases.push({ name: "no_metadata", attrs: phantom.presentation_attrs });
}

process.stdout.write(JSON.stringify({ cases }));
