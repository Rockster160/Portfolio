// Recurrence expander — JS port of AgendaSchedule#matches? + the
// occurrence_date math on the Rails side. Pure functions, no DOM, no
// timezone state. Lets the FE expand a serialize_for_client'd schedule
// into phantom occurrences for any date without a server round-trip.
//
// Any change to the recurrence rule on the Ruby side MUST be ported here
// and verified by spec/javascript/recurrence_parity_spec.rb — that spec
// generates fixtures from Ruby, feeds them to this module via Node, and
// asserts identical output.
//
// Written as CommonJS (`module.exports = …`) so this exact file is
// require()-able from Node for the parity spec AND bundleable by esbuild
// for the browser (esbuild handles both CommonJS and ESM).

const WEEKDAY_KEYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

// Parse "YYYY-MM-DD" into a date-shaped record. All math is done against
// these records (not Date objects with implicit timezones) so the same
// input always produces the same answer regardless of the host timezone.
function parseISO(iso) {
  const [y, m, d] = String(iso).split("-").map(Number);
  // UTC noon gives a stable weekday calculation across every TZ Node
  // could be launched in — DST shifts can't move the wall date away from
  // its calendar position when we're already inside the day.
  const dt = new Date(Date.UTC(y, m - 1, d, 12, 0, 0));
  return { y, m, d, wday: dt.getUTCDay(), iso: String(iso) };
}

function pad2(n) { return String(n).padStart(2, "0"); }

function formatISO(y, m, d) {
  return `${y}-${pad2(m)}-${pad2(d)}`;
}

function addDays(iso, n) {
  const { y, m, d } = parseISO(iso);
  const dt = new Date(Date.UTC(y, m - 1, d + n, 12, 0, 0));
  return formatISO(dt.getUTCFullYear(), dt.getUTCMonth() + 1, dt.getUTCDate());
}

function dayDiff(fromISO, toISO) {
  const a = parseISO(fromISO);
  const b = parseISO(toISO);
  return Math.round((Date.UTC(b.y, b.m - 1, b.d) - Date.UTC(a.y, a.m - 1, a.d)) / 86400000);
}

function monthsBetween(fromISO, toISO) {
  const a = parseISO(fromISO);
  const b = parseISO(toISO);
  return (b.y - a.y) * 12 + (b.m - a.m);
}

function endOfMonthDay(iso) {
  const { y, m } = parseISO(iso);
  // Day 0 of NEXT month is the last day of THIS month.
  const last = new Date(Date.UTC(y, m, 0, 12, 0, 0));
  return last.getUTCDate();
}

// Public API ---------------------------------------------------------------

function matches(schedule, dateISO) {
  if (!schedule || !schedule.starts_on) return false;
  if (dateISO < schedule.starts_on) return false;
  if (schedule.until_on && dateISO > schedule.until_on) return false;
  const excluded = schedule.excluded_dates || [];
  if (excluded.indexOf(dateISO) !== -1) return false;

  switch (schedule.freq || "daily") {
    case "daily":    return true;
    case "weekdays": return matchesWeekdays(dateISO);
    case "weekly":   return matchesWeekly(schedule, dateISO);
    case "monthly":  return matchesMonthly(schedule, dateISO);
    case "yearly":   return matchesYearly(schedule, dateISO);
    case "custom":   return matchesCustom(schedule, dateISO);
    default:         return false;
  }
}

// Materialize every matching date in [fromISO..toISO] (inclusive). Pure
// list; the AgendaStore wires this up with buildPhantom + a suppression
// map for materialized overrides.
function expand(schedule, fromISO, toISO) {
  if (!schedule || !schedule.starts_on) return [];
  // Trim against the schedule's own active window so we never iterate
  // years we know can't match.
  const lower = fromISO < schedule.starts_on ? schedule.starts_on : fromISO;
  const upper = schedule.until_on && toISO > schedule.until_on ? schedule.until_on : toISO;
  if (upper < lower) return [];

  const out = [];
  let cur = lower;
  // Hard cap on iteration: 50 years of days. Way past any sensible
  // window, but a guard against a malformed rule running away.
  const MAX = 50 * 366;
  let count = 0;
  while (cur <= upper && count < MAX) {
    if (matches(schedule, cur)) out.push(cur);
    cur = addDays(cur, 1);
    count += 1;
  }
  return out;
}

// Build an AgendaItem-shaped phantom for `dateISO`. Caller must pass a
// `localEpoch(dateISO, "HH:MM") → seconds_since_epoch` function that
// honors the user's timezone — see ./timezone.js. The optional `agenda`
// lookup lets us populate the agenda-name/color/source presentation
// attrs so the renderer fills the row exactly like a materialized one.
function buildPhantom(schedule, dateISO, { localEpoch, agenda }) {
  const startEpoch = localEpoch(dateISO, schedule.start_time);
  const endEpoch = (schedule.kind === "event" && schedule.duration_minutes)
    ? startEpoch + (Number(schedule.duration_minutes) * 60)
    : null;
  const id = `p-${schedule.id}-${dateISO}`;
  const color = schedule.color || (agenda && agenda.color) || "";
  // Travel metadata is inherited from the schedule's nested `metadata.travel`
  // hash — populated by AgendaTravelChain::Service for the parent schedule.
  // Without this, every phantom rendered a 0-minute band even when the
  // parent schedule's resolver had landed a real travel time (e.g. the
  // recurring TMS event showed the band on today's materialized row but
  // not on Friday's phantom).
  const meta = (schedule && schedule.metadata) || {};
  const travel = (meta && meta.travel) || {};
  // Project the leg array (server sends [{to, drive_seconds, dwell_seconds, ...}])
  // down to the minimal shape the renderer needs. Returning null collapses
  // to the empty-string presentation attr — recurrence schedules without a
  // multi-stop chain stay byte-identical to before.
  const legPayload = (legs) => Array.isArray(legs) && legs.length > 1
    ? legs.map((leg) => ({
        to:             leg.to || "",
        drive_seconds:  Number(leg.drive_seconds) || 0,
        dwell_seconds:  Number(leg.dwell_seconds) || 0,
      }))
    : null;
  // Mirrors `AgendaItem#presentation_attrs` — the renderer reads from
  // this hash; without it phantoms render as blank rows (just the
  // template skeleton: checkbox + edit pencil, no name/time/anything).
  const presentation_attrs = {
    "item-id":              id,
    "item-url":             `/agenda_items/${id}`,
    "phantom":              true,
    "recurring":            true,
    "agenda-schedule-id":   schedule.id,
    "detached":             false,
    "kind":                 schedule.kind,
    "color":                color,
    "agenda-id":            schedule.agenda_id,
    "agenda-name":          agenda ? agenda.name : "",
    "agenda-color":         agenda ? agenda.color : "",
    "agenda-source":        agenda ? agenda.source : "",
    "all-day":              !!schedule.all_day,
    // `end-date` is the INCLUSIVE last-day-midnight epoch (mirrors
    // `AgendaItem#presentation_attrs` and `optimistic_item.js`). For an
    // all-day phantom, `endEpoch` is the exclusive next-day-midnight
    // (start + duration_minutes*60, where Google-synced all-day events
    // always set duration to a multiple of 1440). Walk back one day so
    // the cal_week / cal_month banner layout doesn't render a single-day
    // all-day event across two columns. Was: `endEpoch || startEpoch` —
    // missed the walk-back and made every Google-synced recurring all-day
    // event bleed into the next day's column.
    "end-date":             (!!schedule.all_day && endEpoch) ? (endEpoch - 86400) : (endEpoch || startEpoch),
    "start-at":             startEpoch,
    "end-at":               endEpoch,
    "name":                 schedule.name || "",
    "notes":                schedule.notes || "",
    "location":             schedule.location || "",
    "resolved-address":     travel.location_address || "",
    "arrive-early-minutes": Number(schedule.arrive_early_minutes) || 0,
    "travel-minutes":       Number(travel.travel_minutes) || 0,
    "travel-from-kind":     travel.travel_from_kind || "",
    "travel-from":          travel.travel_from || "",
    "chain-predecessor-id": travel.chain_predecessor_id || "",
    "chain-successor-id":   travel.chain_successor_id || "",
    "chain-prev-end-epoch": travel.chain_prev_end_at || "",
    "leave-at-epoch":       travel.leave_at || "",
    "post-travel-to":       travel.post_travel_to || "",
    "post-travel-minutes":  Number(travel.post_travel_minutes) || 0,
    "post-arrive-at-epoch": travel.post_arrive_at || "",
    "before-legs":          travel.before_legs ? JSON.stringify(legPayload(travel.before_legs)) : "",
    "after-legs":           travel.after_legs ? JSON.stringify(legPayload(travel.after_legs)) : "",
    "trigger-expression":   schedule.trigger_expression || "",
    "schedule":             JSON.stringify(schedule),
    "attendees":            "[]",
    "organizer":            "null",
    "self-response":        "",
  };
  return {
    id:                   id,
    agenda_id:            schedule.agenda_id,
    agenda_name:          agenda ? agenda.name : "",
    agenda_color:         agenda ? agenda.color : "",
    agenda_schedule_id:   schedule.id,
    kind:                 schedule.kind,
    name:                 schedule.name,
    notes:                schedule.notes,
    location:             schedule.location,
    color:                color,
    all_day:              !!schedule.all_day,
    arrive_early_minutes: Number(schedule.arrive_early_minutes) || 0,
    trigger_expression:   schedule.trigger_expression,
    metadata:             schedule.metadata || {},
    start_at:             startEpoch,
    end_at:               endEpoch,
    phantom:              true,
    recurring:            true,
    detached:             false,
    status:               "confirmed",
    completed_at:         null,
    attendees:            [],
    organizer:            null,
    self_response:        "",
    editable:             agenda ? agenda.editable !== false : true,
    schedule:             schedule,
    occurrence_date:      dateISO,
    presentation_attrs:   presentation_attrs,
  };
}

// Frequency helpers --------------------------------------------------------

function matchesWeekdays(dateISO) {
  const { wday } = parseISO(dateISO);
  return wday >= 1 && wday <= 5;
}

function matchesWeekly(schedule, dateISO) {
  const { wday } = parseISO(dateISO);
  return weekdayIndices(schedule).indexOf(wday) !== -1;
}

function weekdayIndices(schedule) {
  const fromRule = (schedule.by_day || [])
    .map((k) => WEEKDAY_KEYS.indexOf(String(k).toLowerCase()))
    .filter((i) => i >= 0);
  if (fromRule.length === 0) return [parseISO(schedule.starts_on).wday];
  return fromRule;
}

function matchesMonthly(schedule, dateISO) {
  // "Nth weekday of month" (e.g. third Tuesday) takes precedence when
  // both by_set_pos and by_day are set — matches Ruby#matches_month_day?.
  if (schedule.by_set_pos && (schedule.by_day || []).length > 0) {
    return matchesNthWeekdayOfMonth(schedule, dateISO);
  }
  const { d } = parseISO(dateISO);
  const days = monthDays(schedule);
  if (days.indexOf(d) !== -1) return true;
  if (days.indexOf(-1) !== -1 && d === endOfMonthDay(dateISO)) return true;
  return false;
}

function monthDays(schedule) {
  const arr = (schedule.by_month_day || []).map((n) => Number(n)).filter((n) => !Number.isNaN(n));
  if (arr.length === 0) return [parseISO(schedule.starts_on).d];
  return arr;
}

function matchesYearly(schedule, dateISO) {
  const start = parseISO(schedule.starts_on);
  const here = parseISO(dateISO);
  return start.m === here.m && start.d === here.d;
}

function matchesCustom(schedule, dateISO) {
  const interval = Math.max(1, Number(schedule.interval) || 1);
  const unit = String(schedule.unit || "day").toLowerCase();
  switch (unit) {
    case "day": {
      return dayDiff(schedule.starts_on, dateISO) % interval === 0;
    }
    case "week": {
      const diff = dayDiff(schedule.starts_on, dateISO);
      if (Math.floor(diff / 7) % interval !== 0) return false;
      return parseISO(schedule.starts_on).wday === parseISO(dateISO).wday;
    }
    case "month": {
      const months = monthsBetween(schedule.starts_on, dateISO);
      if (months % interval !== 0) return false;
      if (schedule.by_set_pos && (schedule.by_day || []).length > 0) {
        return matchesNthWeekdayOfMonth(schedule, dateISO);
      }
      if ((schedule.by_month_day || []).length > 0) {
        return matchesMonthly(schedule, dateISO);
      }
      return parseISO(schedule.starts_on).d === parseISO(dateISO).d;
    }
    default: return false;
  }
}

function matchesNthWeekdayOfMonth(schedule, dateISO) {
  const setPos = Number(schedule.by_set_pos);
  const targetKey = (schedule.by_day || [])[0];
  if (!targetKey) return false;
  const targetWday = WEEKDAY_KEYS.indexOf(String(targetKey).toLowerCase());
  if (targetWday < 0) return false;
  const { y, m, d, wday } = parseISO(dateISO);
  if (wday !== targetWday) return false;

  if (setPos === -1) {
    // last weekday of month: adding 7 days moves into the next month
    const probe = new Date(Date.UTC(y, m - 1, d + 7, 12, 0, 0));
    return (probe.getUTCMonth() + 1) !== m;
  }
  const weekOfMonth = Math.floor((d - 1) / 7) + 1;
  return weekOfMonth === setPos;
}

const Recurrence = {
  matches,
  expand,
  buildPhantom,
  parseISO,
  addDays,
  dayDiff,
};

// CommonJS export so Node can `require` this directly in the parity
// spec without a build step. esbuild also accepts this form and inlines
// it cleanly at bundle time for the browser.
if (typeof module !== "undefined" && module.exports) module.exports = Recurrence;
if (typeof window !== "undefined") window.AgendaRecurrence = Recurrence;
