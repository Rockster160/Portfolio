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

// --- Case 2: full nested travel hash (the only supported shape) ----
// Schedules that have been through the travel-chain resolver carry the
// nested `travel` hash. Every nested field must propagate. (The legacy
// top-level `metadata.travel_minutes` shape is no longer supported —
// AgendaTravelChain migrated it into the nested hash.)
{
  const sched = {
    id: 113, agenda_id: 1, kind: "event", name: "Costco run",
    start_time: "10:00", duration_minutes: 60, all_day: false,
    starts_on: "2026-06-22",
    arrive_early_minutes: 5,
    metadata: {
      travel: {
        travel_minutes:       15,
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

// --- Case 4: return-home baseline (post_travel_minutes mirrored) ---
// A solo recurring event whose schedule carries the return-home baseline
// (minutes + kind) but NOT a per-occurrence post_arrive_at. The phantom
// must derive its OWN arrival epoch = end + minutes so the return band
// renders on future occurrences (mirrors how the incoming "leave by" is
// derived rather than stored).
{
  const sched = {
    id: 115, agenda_id: 1, kind: "event", name: "Yoga",
    start_time: "17:00", duration_minutes: 60, all_day: false,
    starts_on: "2026-06-22",
    metadata: {
      travel: {
        travel_from: "Home St", travel_from_kind: "home", travel_minutes: 12,
        post_travel_to_kind: "home", post_travel_minutes: 12, post_travel_seconds: 720,
      },
    },
  };
  const phantom = Recurrence.buildPhantom(sched, "2026-06-24", { localEpoch, agenda });
  cases.push({ name: "return_home_baseline", attrs: phantom.presentation_attrs });
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
