// Drives AgendaQuickAddParser against the fixture set in
// quick_add_parser_spec.rb. Every fixture pins `now` so the assertions
// are deterministic across the day/night boundary.

const path = require("path");

const { parseQuickAdd, extractDuration } = require(path.resolve(
  __dirname, "..", "..", "app", "javascript", "src", "agenda", "quick_add_parser.js",
));

function fmt(date) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ` +
         `${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function describe(result) {
  if (!result.ok) return { ok: false, error: result.error };
  return {
    ok:          true,
    name:        result.name,
    location:    result.location,
    allDay:      result.allDay,
    durationMin: result.durationMin,
    startsAt:    fmt(result.hints.startDate),
    endsAt:      fmt(result.hints.endDate),
    dayHint:     result.hints.dayHint,
    timeKnown:   result.hints.timeKnown,
  };
}

function run(input, atDate, extraOpts) {
  return describe(parseQuickAdd(input, Object.assign({ now: atDate }, extraOpts || {})));
}

function runFull(input, atDate, extraOpts) {
  // Surfaces agendaId — the agenda-routing fixtures need it.
  const r = parseQuickAdd(input, Object.assign({ now: atDate }, extraOpts || {}));
  const d = describe(r);
  if (r.ok) d.agendaId = r.agendaId;
  return d;
}

// Pinned reference points so cases stay readable.
const MON_10_23 = new Date(2026, 5, 22, 10, 23); // Mon Jun 22 10:23am
const MON_18_00 = new Date(2026, 5, 22, 18, 0);  // Mon Jun 22 6:00pm
const MON_20_00 = new Date(2026, 5, 22, 20, 0);  // Mon Jun 22 8:00pm
const TUE_07_00 = new Date(2026, 5, 23,  7, 0);  // Tue Jun 23 7:00am
const FEB_05    = new Date(2026, 1,  5, 9, 0);   // Thu Feb 5 9:00am

const cases = [
  // === Original three examples =========================================
  { name: "trash_no_time",          result: run("take out the trash", MON_10_23) },
  { name: "trash_at_7_morning",     result: run("take out the trash at 7", MON_10_23) },
  // At 8pm "at 7" — under the nearest-future rule, 7am tomorrow comes
  // sooner than 7pm tomorrow and 7 is outside the 12am-5am skip
  // window, so AM wins.
  { name: "trash_at_7_after_7pm",   result: run("take out the trash at 7", MON_20_00) },
  { name: "lucky_ones_saturday",    result: run("Lucky Ones Saturday at 4 for 3 hours", MON_10_23) },

  // === User-specified intent: tomorrow at 4 (at 6pm) → 4pm tomorrow ====
  { name: "tomorrow_at_4_pm_intent", result: run("Coffee tomorrow at 4", MON_18_00) },
  // Same intent at 7am: still 4pm today (PM default for 4).
  { name: "at_4_morning_pm_default", result: run("Dinner at 4", TUE_07_00) },
  // Explicit "at 4am" survives the heuristic.
  { name: "at_4_am_explicit",        result: run("Run at 4am", TUE_07_00) },

  // === Explicit AM/PM, noon, midnight ==================================
  { name: "noon",        result: run("Lunch at noon", MON_10_23) },
  { name: "midnight",    result: run("Wake at midnight", MON_10_23) },
  { name: "explicit_pm", result: run("Dentist at 3pm", MON_10_23) },
  { name: "explicit_am", result: run("Run at 9am", MON_10_23) },

  // === Always-future ===================================================
  // 9am at 10:23am → tomorrow 9am.
  { name: "future_roll_explicit_am", result: run("Standup at 9am", MON_10_23) },
  // 8 with no am/pm — at 10:23am, 8am has already passed but 8pm is
  // still future, so the nearest-future rule picks 8pm today.
  { name: "future_roll_ambiguous_8", result: run("Standup at 8", MON_10_23) },

  // === Duration variants (mirror jarvis/durations.rb) ==================
  { name: "dur_for_20m",        result: run("Standup for 20m", MON_10_23) },
  { name: "dur_for_an_hour",    result: run("Coffee for an hour", MON_10_23) },
  { name: "dur_half_hour",      result: run("Walk for half hour", MON_10_23) },
  { name: "dur_compound",       result: run("Hospital visit for 1h30m", MON_10_23) },
  { name: "dur_no_for",         result: run("30 minute walk", MON_10_23) },
  // The duration appears before the location; "at Costco" gets split off
  // as a location. Mirrors the spirit of the durations.rb "20 minutes at
  // Costco" case (which exercises duration extraction in isolation).
  { name: "dur_minute_at_end",  result: run("Costco run 20 minutes", MON_10_23) },

  // === Relative offsets ================================================
  { name: "rel_in_3_hours",     result: run("Meeting in 3 hours", MON_10_23) },
  { name: "rel_in_30_min",      result: run("Stretch in 30 minutes", MON_10_23) },
  { name: "rel_from_now",       result: run("Coffee 45 minutes from now", MON_10_23) },
  { name: "rel_in_a_week",      result: run("Project review in a week", MON_10_23) },

  // === Weak day words ==================================================
  { name: "this_evening",       result: run("Dinner this evening", MON_10_23) },
  { name: "tomorrow_morning",   result: run("Workout tomorrow morning", MON_10_23) },
  { name: "in_the_afternoon",   result: run("Errands in the afternoon", MON_10_23) },

  // === Days of week ====================================================
  { name: "next_monday",        result: run("Sprint planning next Monday", MON_10_23) },
  { name: "bare_friday",        result: run("Demo Friday at 2", MON_10_23) },

  // === Date forms ======================================================
  { name: "ordinal_this_month", result: run("Dentist on the 25th", MON_10_23) },
  { name: "ordinal_next_month", result: run("Dentist on the 16th", MON_10_23) },  // Jun 16 < Jun 22 → July 16
  { name: "month_day",          result: run("Trip June 24", MON_10_23) },
  { name: "abbr_month_day",     result: run("Doc Jul 4", MON_10_23) },
  { name: "month_day_with_year", result: run("Conference January 15 2027", MON_10_23) },
  { name: "slash_date",         result: run("Lunch 7/4", MON_10_23) },

  // Ordinal-day month roll for nonexistent days (Feb has no 30th).
  { name: "ordinal_feb_30",     result: run("Reschedule on the 30th", FEB_05) },

  // === Location ========================================================
  // Bare "at X" where X isn't a time → location.
  { name: "loc_costco",            result: run("Groceries at Costco", MON_10_23) },
  // Multi-word, capitalized location keeps its case + words intact.
  { name: "loc_lucky_ones",        result: run("Show at Lucky Ones", MON_10_23) },
  // Time + location side by side. The time wins the first `at`; the
  // trailing `at <place>` becomes location.
  { name: "loc_with_time",         result: run("Dinner at 6pm at Texas Roadhouse", MON_10_23) },
  // Day + time + location.
  { name: "loc_with_day_and_time", result: run("Meeting Friday at 2pm at the office", MON_10_23) },
  // Pure-location, no time hint — defaults to next top of hour.
  { name: "loc_no_time",           result: run("Lunch at Sam's", MON_10_23) },
  // Relative offset + location.
  { name: "loc_with_relative",     result: run("Stretch in 30 minutes at the gym", MON_10_23) },
  // "at noon" must NOT be misread as a location.
  { name: "loc_noon_is_time",      result: run("Lunch at noon", MON_10_23) },

  // === All-day events =================================================
  // `all day` keyword → midnight start, 1-day duration.
  { name: "allday_single",      result: run("Birthday all day Saturday", MON_10_23) },
  // `all-day` hyphenated also matches.
  { name: "allday_hyphenated",  result: run("Vacation all-day Friday", MON_10_23) },
  // Multi-day all-day via "for N days".
  { name: "allday_multi_day",   result: run("Trip all day for 3 days", MON_10_23) },
  // Any clock-time in an all-day phrase is ignored (the user opted in
  // to all-day explicitly).
  { name: "allday_time_ignored", result: run("Conference all day at 9am Tuesday", MON_10_23) },
  // Always-future: today at 6pm + "all day today" should KEEP today
  // (event still happening) — not roll to tomorrow.
  { name: "allday_today_after_noon", result: run("Holiday all day today", new Date(2026, 5, 22, 18, 0)) },

  // === Default-time half-hour snapping ================================
  // Boundary cases for nextHalfHour. The reference time is on the
  // various edges so each path in the helper is exercised.
  { name: "half_at_10_00", result: run("alarm", new Date(2026, 5, 22, 10, 0, 0)) },
  { name: "half_at_10_01", result: run("alarm", new Date(2026, 5, 22, 10, 1, 0)) },
  { name: "half_at_10_29", result: run("alarm", new Date(2026, 5, 22, 10, 29, 0)) },
  { name: "half_at_10_30", result: run("alarm", new Date(2026, 5, 22, 10, 30, 0)) },
  { name: "half_at_10_31", result: run("alarm", new Date(2026, 5, 22, 10, 31, 0)) },
  { name: "half_at_10_59", result: run("alarm", new Date(2026, 5, 22, 10, 59, 0)) },
  // "doit in 4 days" at MON Jun 22 1:12 PM — user's actual example.
  // 1:12pm → next half-hour = 1:30pm; +4 days = Fri Jun 26 at 1:30pm.
  { name: "rel_in_4_days_user", result: run("doit in 4 days", new Date(2026, 5, 22, 13, 12)) },

  // === Errors ==========================================================
  { name: "empty",               result: run("", MON_10_23) },
  { name: "no_name_only_time",   result: run("at 4pm", MON_10_23) },

  // === Nearest-future ambiguous hour (12am-5am skip window) ============
  // 9 at 10:23am → 9am has passed, 9pm is future → 9pm today.
  { name: "ambig_9_morning",  result: run("Storage at 9", MON_10_23) },
  // 9 at 7am → 9am still future, 9am < 9pm → 9am today.
  { name: "ambig_9_early_morning", result: run("Storage at 9", TUE_07_00) },
  // 3 at 4pm → 3am tomorrow is the next occurrence, but 3am is in
  // the 12am-5am skip window → bump to 3pm tomorrow.
  { name: "ambig_3_after_3pm",     result: run("Storage at 3", new Date(2026, 5, 22, 16, 0)) },
  // 12 at 1pm → next 12 = midnight tonight, but that's in the skip
  // window → bump to next noon.
  { name: "ambig_12_after_noon",   result: run("Storage at 12", new Date(2026, 5, 22, 13, 0)) },
  // "tomorrow at 8" at 6pm → tomorrow's AM occurrence (8am) is sooner
  // than tomorrow's PM occurrence (8pm) and 8 is outside the skip
  // window → 8am tomorrow.
  { name: "ambig_tomorrow_at_8",   result: run("Standup tomorrow at 8", MON_18_00) },

  // === From-to range ===================================================
  { name: "range_from_8_to_10",          result: run("Storage from 8 to 10", MON_10_23) },
  { name: "range_from_8_until_10",       result: run("Storage from 8 until 10", MON_10_23) },
  // Explicit meridiems propagate when one end is bare ("from 8 to 10pm").
  { name: "range_from_8_to_10pm",        result: run("Storage from 8 to 10pm", MON_10_23) },
  { name: "range_from_8am_to_10",        result: run("Storage from 8am to 10", MON_10_23) },
  // Multi-hour with explicit AM range starting earlier than now.
  { name: "range_from_9am_to_11am",      result: run("Standup from 9am to 11am", MON_10_23) },
  // Noon/midnight tokens inside the range.
  { name: "range_from_noon_to_3pm",      result: run("Conference from noon to 3pm", MON_10_23) },
  // Half-hour minutes.
  { name: "range_from_8_30_to_10",       result: run("Storage from 8:30 to 10pm", MON_10_23) },
  // Overnight: "from 11pm to 1am" → end on the next day.
  { name: "range_overnight",             result: run("Watch from 11pm to 1am", MON_10_23) },
  // Day hint + range stays on that day.
  { name: "range_with_day_hint",         result: run("Show from 7 to 9 on Friday", MON_10_23) },

  // === Agenda routing ==================================================
  // Leading agenda name routes the event; "Storage" is stripped.
  { name: "agenda_routes_costco",   result: runFull(
    "Costco to Storage at 5", MON_10_23, { agendas: [{ id: 42, name: "Costco" }, { id: 1, name: "Personal" }] },
  ) },
  // No matching agenda → input stays whole, agendaId null.
  { name: "agenda_no_match",        result: runFull(
    "Drive to Costco at 5", MON_10_23, { agendas: [{ id: 1, name: "Personal" }] },
  ) },
  // Multi-word agenda name wins over a substring agenda.
  { name: "agenda_longest_wins",    result: runFull(
    "Family Trips to Disneyland tomorrow", MON_10_23, {
      agendas: [{ id: 7, name: "Family Trips" }, { id: 8, name: "Family" }],
    },
  ) },
  // Case-insensitive match.
  { name: "agenda_case_insensitive", result: runFull(
    "costco to Storage at 5", MON_10_23, { agendas: [{ id: 42, name: "Costco" }] },
  ) },

  // === Pure duration probes (extractDuration only) =====================
  { name: "dur_probe_1h30m",  result: { minutes: extractDuration("1h30m").minutes } },
  { name: "dur_probe_half",   result: { minutes: extractDuration("for half hour").minutes } },
  { name: "dur_probe_ham",    result: { minutes: extractDuration("Eat ham at 5pm").minutes } },
  { name: "dur_probe_9am",    result: { minutes: extractDuration("Coffee tomorrow at 9am").minutes } },
  { name: "dur_probe_empty",  result: { minutes: extractDuration("").minutes } },
];

process.stdout.write(JSON.stringify({ cases }));
