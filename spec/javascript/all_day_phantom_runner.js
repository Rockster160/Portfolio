// Locks the inclusive-last-day convention for the JS recurrence
// expander's all-day phantoms. The cal_week / cal_month banner layouts
// read `presentation_attrs["end-date"]` and compute
// `formatDateISO(new Date(end-date * 1000))` to decide which column the
// chip ends in. If `end-date` carries the exclusive next-day midnight,
// every single-day all-day event spans an extra day — exactly the
// "Tela's Birthday spanning yesterday AND today" bug.

const path = require("path");

const Recurrence = require(path.resolve(
  __dirname, "..", "..", "app", "javascript", "src", "agenda_store", "recurrence.js",
));

// Local-epoch helper: same shape the store hands buildPhantom in prod.
// 86400s per day, midnight is the start_at for an all-day schedule.
// We pin to UTC here because the test only cares about the difference
// between start_at and end-date — both pass through the same epoch math.
function localEpoch(dateISO, timeHHMM) {
  const [h, m] = String(timeHHMM || "00:00").split(":").map(Number);
  return Math.floor(Date.UTC(
    Number(dateISO.slice(0, 4)),
    Number(dateISO.slice(5, 7)) - 1,
    Number(dateISO.slice(8, 10)),
    h || 0, m || 0, 0,
  ) / 1000);
}

const agenda = { id: 7, source: "google", color: "#0160FF", name: "Family" };
const dateISO = "2026-06-21";
const cases = [];

// Single-day all-day event (e.g. Tela's Birthday): duration_minutes = 1440.
// Expected: end-date == start-at, so the chip spans ONE column.
{
  const sched = {
    id:               42, agenda_id: 7, kind: "event", name: "Tela's Birthday",
    start_time:       "00:00", duration_minutes: 1440, all_day: true,
    starts_on:        dateISO,
  };
  const phantom = Recurrence.buildPhantom(sched, dateISO, { localEpoch, agenda });
  cases.push({
    name:           "single_day_all_day",
    start_at:       phantom.presentation_attrs["start-at"],
    end_at:         phantom.presentation_attrs["end-at"],
    end_date_epoch: phantom.presentation_attrs["end-date"],
  });
}

// Three-day all-day event (e.g. a long weekend): duration_minutes = 4320.
// Expected: end-date == start-at + 2 days (the LAST day, inclusive).
{
  const sched = {
    id:               43, agenda_id: 7, kind: "event", name: "Trip",
    start_time:       "00:00", duration_minutes: 4320, all_day: true,
    starts_on:        dateISO,
  };
  const phantom = Recurrence.buildPhantom(sched, dateISO, { localEpoch, agenda });
  cases.push({
    name:           "three_day_all_day",
    start_at:       phantom.presentation_attrs["start-at"],
    end_at:         phantom.presentation_attrs["end-at"],
    end_date_epoch: phantom.presentation_attrs["end-date"],
  });
}

// Timed (non-all-day) event: should NOT trigger the all-day walk-back.
// `end-date` should equal the timed end_at, not end_at - 86400.
{
  const sched = {
    id:               44, agenda_id: 7, kind: "event", name: "1pm Meeting",
    start_time:       "13:00", duration_minutes: 60, all_day: false,
    starts_on:        dateISO,
  };
  const phantom = Recurrence.buildPhantom(sched, dateISO, { localEpoch, agenda });
  cases.push({
    name:           "timed_event_unchanged",
    start_at:       phantom.presentation_attrs["start-at"],
    end_at:         phantom.presentation_attrs["end-at"],
    end_date_epoch: phantom.presentation_attrs["end-date"],
  });
}

process.stdout.write(JSON.stringify({ cases }));
