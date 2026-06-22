// Natural-language parser for the Agenda Quick Add modal. Mirrors the
// capabilities of `app/service/jarvis/times.rb` + `app/service/jarvis/
// durations.rb` so the same phrases the user can speak to Jarvis also
// work in the Agenda's keyboard surface.
//
// Grammar (all phases are order-independent in the input — each phase
// consumes its match from the working string so the remaining text
// becomes the event NAME):
//
//   Duration:
//     "for N (h|hr|hrs|hour|hours|m|min|mins|minute|minutes|s|sec|secs|second|seconds)"
//     "1h 30m", "1h30m"                — compound
//     "an hour", "a minute", "half hour"
//     "30 minute walk"                 — duration without "for"
//
//   Relative offset (resolves a full timestamp directly):
//     "in N (h|min|hr|...)", "in an hour", "in a week"
//     "N units from now"
//
//   Date / Day:
//     "today", "tonight", "tomorrow"
//     "monday", "mon", "tues", "thursday" ...
//     "next monday", "this friday"
//     "(on|for) the 16th"              — current month if still future, else next
//     "june 24", "jun 24", "january 1st"
//     "6/24", "6/24/2026", "6/24/26"
//
//   Weak day qualifiers (require a strong day or "in the"):
//     "tomorrow morning"               → 8am
//     "this evening"                   → 6pm
//     "in the afternoon"               → 2pm
//
//   Time of day:
//     "at 4", "at 4pm", "at 9:30am", "at 4:30"
//     "at noon", "at midnight"
//
// Defaults (when no hint of that type was given):
//   * No time      → next top-of-the-hour
//   * No duration  → 60 minutes
//   * No day       → today
//
// Always future (for Agenda):
//   After resolving, if start <= now, the parser rolls the DAY forward
//   24h at a time until start is strictly after now. AM/PM stays where
//   the user (or the heuristic) put it.
//
// Ambiguous hour disambiguation (no am/pm given):
//   * Hours 1-7   → PM (afternoon meeting intuition; "4" → 4pm)
//   * Hours 8-11  → AM (typical morning)
//   * 0 / 12      → as-is ("at noon" / "at midnight" use their own words)
//
// API:
//   parseQuickAdd(input, { now, defaultDurationMin })
//     → { ok: true, name, startAt, endAt, durationMin, hints: {...} }
//     → { ok: false, name: "", error: "empty" | "missing_name" }

// ----- Duration grammar (mirrors jarvis/durations.rb) -----------------

const UNIT_MIN = {
  s: 1 / 60, sec: 1 / 60, secs: 1 / 60, second: 1 / 60, seconds: 1 / 60,
  m: 1, min: 1, mins: 1, minute: 1, minutes: 1,
  h: 60, hr: 60, hrs: 60, hour: 60, hours: 60,
  // Day/week units are mostly useful for all-day events ("Vacation all
  // day for 3 days") but harmless for the timed path too — a "for 2
  // days" timed event reads as a 2880-min span, which is rare but
  // unambiguous.
  day: 1440, days: 1440,
  week: 10080, weeks: 10080,
};
const UNIT_KEYS_DESC = Object.keys(UNIT_MIN).sort((a, b) => b.length - a.length);
const UNIT_RE_SRC = UNIT_KEYS_DESC.join("|");
const NON_UNIT_LETTER = "a-gi-ln-rt-z"; // blocks mid-word matches but allows compound h/m/s adjacency
const QTY_RE_SRC = "(?:\\d+(?:\\.\\d+)?|an?|half)";
// `(?<=\d)|\s+` — qty→unit gap: digit-adjacent (1h, 1.5m) OR whitespace
// (a min, half hour). Word qty must be space-separated so "Sam"/"ham" can't
// be misread as `a m`.
const QTY_UNIT_GAP = "(?:(?<=\\d)|\\s+)";
const DUR_ATOM_RE = new RegExp(
  `(?<![${NON_UNIT_LETTER}])(\\d+(?:\\.\\d+)?|an?|half)${QTY_UNIT_GAP}(${UNIT_RE_SRC})(?![a-zA-Z])`,
  "gi",
);
const DUR_STRIP_RE = new RegExp(
  `(?:\\bfor\\s+|\\band\\s+)?(?<![${NON_UNIT_LETTER}])${QTY_RE_SRC}${QTY_UNIT_GAP}(?:${UNIT_RE_SRC})(?![a-zA-Z])\\s*`,
  "gi",
);

// Mirrors Jarvis::Durations.extract — total minutes across every
// qty+unit atom in the text. Returns `{ minutes, rest, matched }`:
//   * `minutes` is always a number (0 if nothing matched), so callers
//     that just want "how many minutes is this string?" can read it
//     directly the same way the Ruby helper works.
//   * `matched` is the boolean the QuickAdd parser uses to decide
//     whether to apply the user-stated duration or fall back to the
//     default 60-minute event length.
//   * `rest` is the input with every duration atom (and any leading
//     "for"/"and") removed, so callers can strip duration out of a
//     phrase and keep the rest as the event name.
function extractDuration(text) {
  let minutes = 0;
  let matched = false;
  String(text || "").replace(DUR_ATOM_RE, (_, qty, unit) => {
    matched = true;
    const q = qty.toLowerCase();
    const n = q === "a" || q === "an" ? 1 : q === "half" ? 0.5 : parseFloat(q);
    minutes += n * UNIT_MIN[unit.toLowerCase()];
    return "";
  });
  const rest = matched
    ? String(text || "").replace(DUR_STRIP_RE, " ").replace(/\s{2,}/g, " ").trim()
    : String(text || "");
  return { minutes: Math.round(minutes), rest, matched };
}

// ----- Day / date grammar --------------------------------------------

const DOW = {
  sun: 0, sunday: 0,
  mon: 1, monday: 1,
  tue: 2, tues: 2, tuesday: 2,
  wed: 3, weds: 3, wednesday: 3,
  thu: 4, thur: 4, thurs: 4, thursday: 4,
  fri: 5, friday: 5,
  sat: 6, saturday: 6,
};
const DOW_KEYS = Object.keys(DOW).sort((a, b) => b.length - a.length);
const MONTHS = {
  january: 0, jan: 0,
  february: 1, feb: 1,
  march: 2, mar: 2,
  april: 3, apr: 3,
  may: 4,
  june: 5, jun: 5,
  july: 6, jul: 6,
  august: 7, aug: 7,
  september: 8, sept: 8, sep: 8,
  october: 9, oct: 9,
  november: 10, nov: 10,
  december: 11, dec: 11,
};
const MONTH_KEYS = Object.keys(MONTHS).sort((a, b) => b.length - a.length);

const STRONG_DAY_RE   = new RegExp(`\\b(today|tonight|tomorrow)\\b`, "i");
const NEXT_DOW_RE     = new RegExp(`\\b(?:next|this)\\s+(${DOW_KEYS.join("|")})\\b`, "i");
const BARE_DOW_RE     = new RegExp(`\\b(${DOW_KEYS.join("|")})\\b`, "i");
const MONTH_DAY_RE    = new RegExp(`\\b(${MONTH_KEYS.join("|")})\\s+(\\d{1,2})(?:st|nd|rd|th)?(?:,?\\s*(\\d{2,4}))?\\b`, "i");
const SLASH_DATE_RE   = /\b(\d{1,2})\/(\d{1,2})(?:\/(\d{2,4}))?\b/;
const ORDINAL_DAY_RE  = /\b(?:on|for)\s+the\s+(\d{1,2})(?:st|nd|rd|th)?\b/i;

const WEAK_DAY_RE     = /\b(?:this\s+|tomorrow\s+|in\s+the\s+)(morning|afternoon|evening|night)\b/i;
const WEAK_HOURS      = { morning: 8, afternoon: 14, evening: 18, night: 20 };

// ----- Time grammar --------------------------------------------------

const NOON_RE     = /\bat\s+noon\b/i;
const MIDNIGHT_RE = /\bat\s+midnight\b/i;
const CLOCK_RE    = /\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm|a|p)?\b/i;

// ----- All-day grammar -----------------------------------------------
// "all day", "all-day", "allday" anywhere in the input opts this event
// into the all-day path: start at midnight of the target date, duration
// defaults to 1 day (or whatever "for N days" specified).
const ALL_DAY_RE = /\ball[-\s]?day\b/i;

// ----- Location grammar ----------------------------------------------
// `at` is overloaded ("at 4pm" is a time, "at Costco" is a location).
// We only treat it as a location if the next non-space token is NOT
// `noon`, `midnight`, or a leading-digit clock (`4`, `9:30`). The
// match is greedy to end-of-string so "at the corner of 5th and Main"
// keeps multi-word places intact — the parser runs this AFTER every
// other phase has consumed its own substring, so the only stragglers
// left are the name and the location.
//
// Anchored to end-of-string for two reasons: (1) most "at X" usage
// trails the event name ("Dinner at Costco"), and (2) it keeps the
// regex from gobbling earlier tokens. If a user writes "at Costco
// tomorrow" the `tomorrow` phase strips its piece before this fires,
// leaving "at Costco" at the tail.
const LOCATION_RE = /\bat\s+(?!\d|noon\b|midnight\b)(.+?)\s*$/i;

// ----- Relative-offset grammar ---------------------------------------

const IN_OFFSET_RE  = new RegExp(`\\bin\\s+(${QTY_RE_SRC})${QTY_UNIT_GAP}(${UNIT_RE_SRC}|days?|weeks?|months?|years?)(?![a-zA-Z])`, "i");
const FROM_NOW_RE   = new RegExp(`(${QTY_RE_SRC})${QTY_UNIT_GAP}(${UNIT_RE_SRC}|days?|weeks?|months?|years?)\\s+from\\s+now`, "i");

const OFFSET_UNIT_MIN = Object.assign({}, UNIT_MIN, {
  day: 1440, days: 1440,
  week: 10080, weeks: 10080,
  month: 43800, months: 43800, // ~30.4 days
  year: 525600, years: 525600,
});

// Day-level offsets carry no time-of-day intent ("in 4 days" doesn't
// imply 4 days from this exact second — it implies "the same default
// scheduling moment, 4 days later"), so the start anchors to the next
// half-hour from now and then adds the day offset. Sub-day offsets
// ("in 30 minutes", "in 3 hours") are precise and DO use exact now.
const DAY_LEVEL_UNIT_RE = /^(?:day|days|week|weeks|month|months|year|years)$/i;

function parseRelativeOffset(text, now) {
  const tryRe = (re) => {
    const m = text.match(re);
    if (!m) return null;
    const qty = m[1].toLowerCase();
    const unit = m[2].toLowerCase();
    const n = qty === "a" || qty === "an" ? 1 : qty === "half" ? 0.5 : parseFloat(qty);
    const minPerUnit = OFFSET_UNIT_MIN[unit];
    if (!minPerUnit) return null;
    return { minutes: n * minPerUnit, dayLevel: DAY_LEVEL_UNIT_RE.test(unit), match: m };
  };
  const hit = tryRe(IN_OFFSET_RE) || tryRe(FROM_NOW_RE);
  if (!hit) return null;
  const base = hit.dayLevel ? nextHalfHour(now) : now;
  const start = new Date(base.getTime() + hit.minutes * 60 * 1000);
  const rest = (text.slice(0, hit.match.index) + text.slice(hit.match.index + hit.match[0].length))
                  .replace(/\s{2,}/g, " ").trim();
  return { start, rest };
}

// ----- Helpers --------------------------------------------------------

function consume(text, re) {
  const m = text.match(re);
  if (!m) return { match: null, rest: text };
  const rest = (text.slice(0, m.index) + text.slice(m.index + m[0].length))
                  .replace(/\s{2,}/g, " ").trim();
  return { match: m, rest };
}

function ordinalDate(day, now) {
  if (day < 1 || day > 31) return null;
  const candidate = new Date(now.getFullYear(), now.getMonth(), day);
  if (candidate.getDate() === day && candidate >= startOfDay(now)) return candidate;
  for (let i = 1; i <= 12; i++) {
    const d = new Date(now.getFullYear(), now.getMonth() + i, day);
    if (d.getDate() === day) return d;
  }
  return null;
}

function startOfDay(d) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate());
}

function addDays(d, n) {
  const r = new Date(d);
  r.setDate(r.getDate() + n);
  return r;
}

// "Next half hour" — rounds `now` up to the next :00 or :30 boundary,
// always producing a strictly-future Date. The Quick Add modal uses
// this as its default scheduling moment when the user gives no time
// hint, and the relative-offset path applies it for day-level units
// ("in 4 days") since those carry no time-of-day intent.
//
//   1:00 → 1:30        1:30 → 2:00
//   1:01 → 1:30        1:31 → 2:00
//   1:29 → 1:30        1:59 → 2:00
function nextHalfHour(now) {
  const t = new Date(now.getTime());
  t.setSeconds(0, 0);
  const m = t.getMinutes();
  if (m < 30) {
    t.setMinutes(30);
  } else {
    t.setMinutes(0);
    t.setHours(t.getHours() + 1);
  }
  // Anchor-exact-boundary case: setSeconds zeroed out a sub-minute
  // remainder, so the new `t` may equal `now`. Bump once more.
  if (t.getTime() <= now.getTime()) {
    t.setMinutes(t.getMinutes() + 30);
  }
  return t;
}

// ----- Main parser ---------------------------------------------------

function parseQuickAdd(rawInput, opts) {
  const cfg = Object.assign({
    now:                new Date(),
    defaultDurationMin: 60,
  }, opts || {});
  const now = cfg.now;
  let work = String(rawInput || "").trim();
  if (!work) return { ok: false, name: "", error: "empty" };

  // Detect (and strip) the all-day keyword up front. Any time hint that
  // appears alongside it is ignored — "all day at 4pm" makes no sense;
  // all-day wins. Duration semantics for all-day events come in days,
  // not minutes — see the duration-extraction phase below.
  let isAllDay = false;
  if (ALL_DAY_RE.test(work)) {
    isAllDay = true;
    work = work.replace(ALL_DAY_RE, " ").replace(/\s{2,}/g, " ").trim();
  }

  // 1. Relative offset short-circuits the date/time machinery — "in 3
  // hours", "30 minutes from now" produce a concrete startDate.
  const rel = parseRelativeOffset(work, now);
  if (rel) {
    work = rel.rest;
    // Strip any leftover duration so "in 3 hours" doesn't also count as a
    // 3-hour event duration.
    const dur2 = extractDuration(work);
    if (dur2.matched) work = dur2.rest;
    // Pull the location out of the residue ("Meeting in 3 hours at Costco").
    let relLocation = null;
    {
      const { match, rest: r2 } = consume(work, LOCATION_RE);
      if (match) { relLocation = match[1].trim(); work = r2; }
    }
    const name = work.replace(/\s{2,}/g, " ").trim();
    if (!name) return { ok: false, name: "", error: "missing_name" };
    const durationMin = cfg.defaultDurationMin;
    const endDate = new Date(rel.start.getTime() + durationMin * 60 * 1000);
    return successResult(name, rel.start, endDate, durationMin, {
      timeKnown: true, dayHint: "relative", durationKnown: false, location: relLocation, allDay: false,
    });
  }

  // 2. Duration extraction.
  let durationMin = null;
  const dur = extractDuration(work);
  if (dur.matched && dur.minutes > 0) {
    durationMin = dur.minutes;
    work = dur.rest;
  }

  // 3. Date / day phase. The first hit wins, but each phase strips its
  // own substring so the residue feeds cleanly into the next.
  let targetDate = null;
  let dayHint = null;

  // 3-pre. Weak day qualifier — must run BEFORE the strong-day phase
  // because patterns like "tomorrow morning" prefix a strong day with a
  // weak period. Consuming the strong day first would orphan "morning"
  // (no qualifier left → won't match → default to top-of-the-hour). Set
  // the day AND time in one go here.
  let pendingTimeFromWeak = null;
  {
    const { match, rest } = consume(work, WEAK_DAY_RE);
    if (match) {
      const period = match[1].toLowerCase();
      pendingTimeFromWeak = { hour: WEAK_HOURS[period], minute: 0 };
      if (/tomorrow/i.test(match[0])) {
        targetDate = addDays(startOfDay(now), 1);
        dayHint = "tomorrow";
      } else if (/this/i.test(match[0])) {
        targetDate = startOfDay(now);
        dayHint = "today";
      }
      // "in the morning" leaves the day to be filled in by a later
      // strong-day-or-default phase.
      work = rest;
    }
  }

  // 3a. (on|for) the 16th — current/next month.
  {
    const { match, rest } = consume(work, ORDINAL_DAY_RE);
    if (match) {
      const d = ordinalDate(parseInt(match[1], 10), now);
      if (d) { targetDate = d; dayHint = `the ${match[1]}`; work = rest; }
    }
  }

  // 3b. "January 24" / "Jan 24" / "January 1st" / "Jan 24, 2027".
  if (!targetDate) {
    const { match, rest } = consume(work, MONTH_DAY_RE);
    if (match) {
      const monthIdx = MONTHS[match[1].toLowerCase()];
      const day      = parseInt(match[2], 10);
      const yearRaw  = match[3] ? parseInt(match[3], 10) : null;
      const year     = yearRaw == null ? now.getFullYear()
                      : yearRaw < 100 ? 2000 + yearRaw
                      : yearRaw;
      const cand = new Date(year, monthIdx, day);
      if (cand.getDate() === day && cand.getMonth() === monthIdx) {
        // If user omitted the year and the date already passed this year,
        // bump to next year so the result is future.
        if (yearRaw == null && cand < startOfDay(now)) {
          cand.setFullYear(year + 1);
        }
        targetDate = cand;
        dayHint = `${match[1]} ${day}`;
        work = rest;
      }
    }
  }

  // 3c. Slash dates.
  if (!targetDate) {
    const { match, rest } = consume(work, SLASH_DATE_RE);
    if (match) {
      const monthIdx = parseInt(match[1], 10) - 1;
      const day      = parseInt(match[2], 10);
      const yearRaw  = match[3] ? parseInt(match[3], 10) : null;
      const year     = yearRaw == null ? now.getFullYear()
                      : yearRaw < 100 ? 2000 + yearRaw
                      : yearRaw;
      const cand = new Date(year, monthIdx, day);
      if (cand.getMonth() === monthIdx && cand.getDate() === day) {
        if (yearRaw == null && cand < startOfDay(now)) cand.setFullYear(year + 1);
        targetDate = cand;
        dayHint = `${match[1]}/${match[2]}`;
        work = rest;
      }
    }
  }

  // 3d. "next monday" / "this friday".
  if (!targetDate) {
    const { match, rest } = consume(work, NEXT_DOW_RE);
    if (match) {
      const targetDow = DOW[match[1].toLowerCase()];
      const base = startOfDay(now);
      let delta = targetDow - base.getDay();
      if (delta <= 0) delta += 7;
      targetDate = addDays(base, delta);
      dayHint = match[1].toLowerCase();
      work = rest;
    }
  }

  // 3e. Strong day word (today | tonight | tomorrow).
  if (!targetDate) {
    const { match, rest } = consume(work, STRONG_DAY_RE);
    if (match) {
      const w = match[1].toLowerCase();
      const base = startOfDay(now);
      targetDate = w === "tomorrow" ? addDays(base, 1) : base;
      dayHint = w;
      work = rest;
    }
  }

  // 3f. Bare weekday name (mon..sun).
  if (!targetDate) {
    const { match, rest } = consume(work, BARE_DOW_RE);
    if (match) {
      const targetDow = DOW[match[1].toLowerCase()];
      const base = startOfDay(now);
      let delta = targetDow - base.getDay();
      if (delta <= 0) delta += 7;
      targetDate = addDays(base, delta);
      dayHint = match[1].toLowerCase();
      work = rest;
    }
  }

  // 4. Time of day — explicit clock OR weak day word. Skipped entirely
  // when `all day` was given: all-day events are anchored to midnight
  // and any clock-time hint in the input is intentionally ignored.
  let hour = null;
  let minute = 0;
  let meridiem = null;
  let timeKnown = false;

  if (!isAllDay) {
    if (NOON_RE.test(work)) {
      hour = 12; minute = 0; meridiem = "pm"; timeKnown = true;
      work = work.replace(NOON_RE, "").replace(/\s{2,}/g, " ").trim();
    } else if (MIDNIGHT_RE.test(work)) {
      hour = 0; minute = 0; meridiem = "am"; timeKnown = true;
      work = work.replace(MIDNIGHT_RE, "").replace(/\s{2,}/g, " ").trim();
    } else {
      const { match, rest } = consume(work, CLOCK_RE);
      if (match) {
        const h = parseInt(match[1], 10);
        const m = match[2] ? parseInt(match[2], 10) : 0;
        const ap = match[3] ? match[3].toLowerCase()[0] : null;
        if (h >= 0 && h <= 23 && m >= 0 && m <= 59) {
          hour = h;
          minute = m;
          meridiem = ap === "p" ? "pm" : ap === "a" ? "am" : null;
          timeKnown = true;
          work = rest;
        }
      }
    }

    // 4b. Apply the weak-day-qualifier time (resolved in phase 3-pre)
    // unless an explicit clock already won.
    if (!timeKnown && pendingTimeFromWeak) {
      hour = pendingTimeFromWeak.hour;
      minute = pendingTimeFromWeak.minute;
      meridiem = hour >= 12 ? "pm" : "am";
      timeKnown = true;
    }
  }

  // 4c. Location — `at <place>` where <place> doesn't look like a time.
  // Runs after the time + day phases so "at 4pm" was already plucked
  // out and we only see the trailing "at Costco" / "at Lucky Ones"
  // half of the input.
  let location = null;
  {
    const { match, rest } = consume(work, LOCATION_RE);
    if (match) {
      location = match[1].trim();
      work = rest;
    }
  }

  // 5. Whatever remains is the name.
  const name = work
    .replace(/\s+(at|on|for|in|the)\s*$/i, "")  // strip leftover prepositions at the tail
    .replace(/^(at|on|for|in|the)\s+/i, "")     // strip leftover prepositions at the head
    .replace(/\s{2,}/g, " ")
    .trim();
  if (!name) return { ok: false, name: "", error: "missing_name" };

  // 6. Default day if none extracted.
  if (!targetDate) {
    targetDate = startOfDay(now);
  }

  // 7. Resolve the hour-of-day.
  let startDate;
  if (isAllDay) {
    // All-day events anchor to midnight of the target date. No top-of-
    // hour default, no clock parse — both are intentionally ignored
    // when `all day` is in the input.
    startDate = new Date(targetDate);
    startDate.setHours(0, 0, 0, 0);
  } else if (!timeKnown) {
    // Default: next half-hour from `now`. Applied as HH:MM to whichever
    // target date the day phase picked (today by default; could be next
    // Friday, Jul 4, etc.). Late-night safety: if the user is asking
    // about "today" and the snapped time landed in the wee hours of
    // tomorrow, prefer 9am tomorrow over a 12:30am default.
    const halfHour = nextHalfHour(now);
    startDate = new Date(targetDate);
    startDate.setHours(halfHour.getHours(), halfHour.getMinutes(), 0, 0);
    if (dayHint == null && now.getHours() >= 22 && halfHour.getHours() <= 6) {
      startDate = addDays(startDate, 1);
      startDate.setHours(9, 0, 0, 0);
    }
  } else {
    let h24 = hour;
    if (meridiem === "pm" && hour < 12) h24 = hour + 12;
    else if (meridiem === "am" && hour === 12) h24 = 0;
    else if (meridiem == null && hour >= 1 && hour <= 11) {
      // Ambiguous: 1-7 → PM (afternoon meeting intuition), 8-11 → AM.
      h24 = (hour <= 7) ? hour + 12 : hour;
    }
    startDate = new Date(targetDate);
    startDate.setHours(h24, minute, 0, 0);
  }

  // Resolve duration. All-day events default to a full day (1440 min)
  // when no `for N days/weeks` was given.
  const defaultDur = isAllDay ? 1440 : cfg.defaultDurationMin;
  const durMin = durationMin != null ? durationMin : defaultDur;
  let endDate = new Date(startDate.getTime() + durMin * 60 * 1000);

  // 8. ALWAYS future. Gates on the EVENT END so that an all-day event
  // for today (start at midnight = past, but the event spans the rest
  // of the day) doesn't roll forward unnecessarily. For timed events
  // this still rolls past-due times to tomorrow same-time.
  while (endDate <= now) {
    startDate = addDays(startDate, 1);
    endDate = addDays(endDate, 1);
  }

  return successResult(name, startDate, endDate, durMin, {
    dayHint, timeKnown, durationKnown: durationMin != null, location, allDay: isAllDay,
  });
}

function successResult(name, startDate, endDate, durationMin, hints) {
  return {
    ok:          true,
    name,
    location:    hints.location || null,
    allDay:      !!hints.allDay,
    startAt:     Math.floor(startDate.getTime() / 1000),
    endAt:       Math.floor(endDate.getTime()   / 1000),
    durationMin,
    hints:       Object.assign({ startDate, endDate }, hints),
  };
}

const AgendaQuickAddParser = { parseQuickAdd, extractDuration };

if (typeof module !== "undefined" && module.exports) module.exports = AgendaQuickAddParser;
if (typeof window !== "undefined") window.AgendaQuickAddParser = AgendaQuickAddParser;
