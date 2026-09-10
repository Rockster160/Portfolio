// Drives AgendaStore.scheduleOccurrences — the read the search modal
// uses to reach a recurring series that has no materialized row yet.
// Boots a store holding a yearly birthday (rule only, zero items), a
// weekly standup with one materialized row, and reports what each
// window hands back.

const path = require("path");

global.window = { localStorage: undefined };

const SRC = path.resolve(__dirname, "..", "..", "app", "javascript", "src", "agenda_store");
const AgendaStore = require(path.join(SRC, "store.js"));
const Tz          = require(path.join(SRC, "timezone.js"));

const TZ    = "America/Denver";
const TODAY = "2026-06-22";

const BIRTHDAY = {
  id:               149,
  agenda_id:        32,
  name:             "Whisper's Birthday",
  kind:             "event",
  freq:             "yearly",
  interval:         1,
  starts_on:        "2000-10-14",
  until_on:         null,
  all_day:          true,
  start_time:       "00:00",
  excluded_dates:   [],
};

const STANDUP = {
  id:               7,
  agenda_id:        1,
  name:             "Tech Stand-Up",
  kind:             "event",
  freq:             "weekly",
  interval:         1,
  by_day:           ["mo"],
  starts_on:        "2026-01-05",
  until_on:         null,
  start_time:       "09:00",
  duration_minutes: 30,
  excluded_dates:   [],
};

// The one occurrence the server has actually written down — today's
// standup. A phantom beside it would be the same morning listed twice.
const STANDUP_ROW = {
  id:                 "5001",
  agenda_id:          1,
  agenda_schedule_id: 7,
  name:               "Tech Stand-Up",
  kind:               "event",
  start_at:           localEpoch(TODAY, "09:00"),
  end_at:             localEpoch(TODAY, "09:30"),
  status:             "confirmed",
  detached:           false,
};

// The store's own wall-clock→epoch conversion, so the seeded row lands
// on exactly the instant a phantom for the same date would.
function localEpoch(dateISO, hhmm) {
  return Tz.localEpoch(dateISO, hhmm, TZ);
}

function boot() {
  AgendaStore.reset();
  AgendaStore.applyBootstrap({
    server_ts: 1_700_000_000_000,
    day_key:   TODAY,
    timezone:  TZ,
    items:     [STANDUP_ROW],
    agendas:   [
      { id: 32, name: "Birthdays", color: "#e91e63", editable: false },
      { id: 1,  name: "Work",      color: "#2196f3", editable: true },
    ],
    schedules: [BIRTHDAY, STANDUP],
  });
}

function named(fragment) {
  return (sched) => (sched.name || "").toLowerCase().includes(fragment);
}

function addDays(dateISO, n) {
  const d = new Date(`${dateISO}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

function summarize(rows) {
  return rows.map((r) => ({
    id:                 r.id,
    name:               r.name,
    agenda_schedule_id: r.agenda_schedule_id,
    all_day:            r.all_day,
    editable:           r.editable,
    occurrence_date:    r.occurrence_date,
  }));
}

boot();

const out = {
  // The whole point: a yearly rule with no row anywhere is still found.
  birthday_forward: summarize(AgendaStore.scheduleOccurrences(
    named("whisper"), TODAY, addDays(TODAY, 730), { perSchedule: 12 },
  )),
  // Backwards windows want the most recent, not the oldest.
  birthday_back: summarize(AgendaStore.scheduleOccurrences(
    named("whisper"), addDays(TODAY, -365), TODAY, { perSchedule: 1, take: "last" },
  )),
  // A materialized row already stands for its date; no phantom beside it.
  standup_forward: summarize(AgendaStore.scheduleOccurrences(
    named("stand-up"), TODAY, addDays(TODAY, 21), { perSchedule: 12 },
  )),
  // A predicate that matches nothing walks no rules.
  no_match: summarize(AgendaStore.scheduleOccurrences(
    named("dentist"), TODAY, addDays(TODAY, 730), { perSchedule: 12 },
  )),
  // The refactor that extracted the suppression map must leave the
  // calendar's own read alone.
  range_today: summarize(AgendaStore.itemsForRange(TODAY, TODAY)),
};

process.stdout.write(JSON.stringify(out));
