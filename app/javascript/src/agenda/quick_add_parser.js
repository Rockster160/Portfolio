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
//   Pick the NEAREST future occurrence of the time on the target date
//   (AM if earlier and still future, else PM), EXCEPT when the AM
//   occurrence falls in the 12am-5am window — those are skipped to the
//   matching PM time. Concretely:
//     * Hours 1-5  → PM (skip 12am-5am AM range)
//     * Hour  12   → 12pm noon (skip midnight)
//     * Hours 6-11 → pick AM vs PM by which one is the nearer future
//                    moment; if both are past, AM wins (always-future
//                    gate rolls the day forward).
//
// API:
//   parseQuickAdd(input, { now, defaultDurationMin, defaultDate })
//     → { ok: true, name, startAt, endAt, durationMin, hints: {...} }
//     → { ok: false, name: "", error: "empty" | "missing_name" }
//
// `defaultDate` (YYYY-MM-DD, optional) is the fallback target day when
// the input carries no date hint — used by the Day/Week pages so quick
// adds land on the currently-viewed date, not today.

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

// "from 8 to 10", "from 8am until 10:30pm", "from noon to 3pm".
// Both ends optionally carry am/pm; meridiem propagation is resolved
// in phase 7 so it can lean on the same NEAREST-future heuristic as
// the bare-clock parser. "to|until|till|thru|through|-" all delimit.
const RANGE_END_RE_SRC = "(?:to|until|till|thru|through|\\-)";
const RANGE_RE = new RegExp(
  "\\bfrom\\s+" +
    "(noon|midnight|\\d{1,2}(?::\\d{2})?)\\s*(am|pm|a|p)?" +
    `\\s+${RANGE_END_RE_SRC}\\s+` +
    "(noon|midnight|\\d{1,2}(?::\\d{2})?)\\s*(am|pm|a|p)?\\b",
  "i",
);

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

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Build a regex fragment that matches an agenda name under
// normalization: lowercased, split into alphanumeric words, joined by
// permissive `[^a-z0-9]+` gaps so spaces/punctuation/emoji between the
// words don't matter, with a trailing `[^a-z0-9]*` that eats optional
// decorators (e.g. an emoji suffix). `normLen` is the alphanumeric-only
// character count — used as the tiebreaker so longer names beat shorter
// prefixes ("Family Trips" wins over "Family").
function normalizedAgendaPattern(name) {
  const words = String(name || "").toLowerCase().split(/[^a-z0-9]+/i).filter(Boolean);
  if (!words.length) return null;
  const regex = words.map(escapeRegex).join("[^a-z0-9]+") + "[^a-z0-9]*";
  return { regex, normLen: words.reduce((n, w) => n + w.length, 0) };
}

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

// YYYY-MM-DD → local-midnight Date, or null for missing/malformed input.
// Using the numeric constructor avoids `new Date("2026-07-20")` parsing
// as UTC (which shifts one day back in negative timezones).
function parseDefaultDate(iso) {
  if (!iso || typeof iso !== "string") return null;
  const m = iso.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (!m) return null;
  return new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]));
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

// Pick the 24-hour value for a bare ambiguous clock entry (no am/pm).
// See the file header "Ambiguous hour disambiguation" block for the
// full rule — this is the implementation.
function pickAmbiguousMeridiem(hour, minute, targetDate, now) {
  // Hours 1-5 and 12 are always-PM (the AM occurrence lands in
  // 12am-5am, which the rule unconditionally skips).
  if (hour === 12) return 12;
  if (hour >= 1 && hour <= 5) return hour + 12;
  // Hours 6-11: pick whichever occurrence on targetDate is the nearest
  // strictly-future moment. If AM is future and not later than PM,
  // take AM. Else if PM is future, take PM. If both are past, fall
  // back to AM — the always-future gate then rolls the day forward,
  // and AM tomorrow comes before PM tomorrow.
  const am = new Date(targetDate);
  am.setHours(hour, minute, 0, 0);
  const pm = new Date(targetDate);
  pm.setHours(hour + 12, minute, 0, 0);
  if (am > now && (pm <= now || am <= pm)) return hour;
  if (pm > now) return hour + 12;
  return hour;
}

// Parse a single clock spec from the from-to grammar — a numeric "H"
// or "H:MM", or the words "noon"/"midnight". Returns null for shapes
// that don't fit (out-of-range hours/minutes).
function parseClockSpec(spec) {
  const token = spec.token;
  if (token === "noon")     return { hour: 12, minute: 0, ap: "p", forced: true };
  if (token === "midnight") return { hour: 0,  minute: 0, ap: "a", forced: true };
  const m = token.match(/^(\d{1,2})(?::(\d{2}))?$/);
  if (!m) return null;
  const h = parseInt(m[1], 10);
  const min = m[2] ? parseInt(m[2], 10) : 0;
  if (h < 0 || h > 23 || min > 59) return null;
  return { hour: h, minute: min, ap: spec.ap, forced: false };
}

// Apply an explicit am/pm token to an hour, returning the 24-hour value.
function applyAp(hour, ap) {
  if (ap === "p" && hour < 12)   return hour + 12;
  if (ap === "a" && hour === 12) return 0;
  return hour;
}

// Resolve a from-to range into concrete startDate / endDate on the
// given target date. Meridiem propagates from explicit→ambiguous; if
// both ambiguous, the start uses the same nearest-future picker as
// the bare clock and the end picks the meridiem that puts it strictly
// after the start (overnight ranges are honored if both ends land
// past midnight). Either end can be `noon`/`midnight` (forced).
function resolveRange(range, targetDate, now) {
  const s = parseClockSpec(range.startSpec) || { hour: 0, minute: 0, ap: null, forced: false };
  const e = parseClockSpec(range.endSpec)   || { hour: 0, minute: 0, ap: null, forced: false };

  let sH;
  let eH;

  if (s.forced) {
    sH = applyAp(s.hour, s.ap);
  } else if (s.ap) {
    sH = applyAp(s.hour, s.ap);
  } else if (e.ap && !e.forced) {
    // Explicit end meridiem propagates to ambiguous start.
    sH = applyAp(s.hour, e.ap);
  } else {
    sH = pickAmbiguousMeridiem(s.hour, s.minute, targetDate, now);
  }

  if (e.forced) {
    eH = applyAp(e.hour, e.ap);
  } else if (e.ap) {
    eH = applyAp(e.hour, e.ap);
  } else {
    // Prefer the same-half-of-day meridiem as the start, fall back to
    // the opposite if the same one makes end<=start. Last resort:
    // accept whatever and treat as overnight.
    const sameAp = sH >= 12 ? "p" : "a";
    const sameH = applyAp(e.hour, sameAp);
    if (sameH > sH) {
      eH = sameH;
    } else {
      const altH = applyAp(e.hour, sameAp === "p" ? "a" : "p");
      eH = altH > sH ? altH : sameH;
    }
  }

  const startDate = new Date(targetDate);
  startDate.setHours(sH, s.minute, 0, 0);
  const endDate = new Date(targetDate);
  endDate.setHours(eH, e.minute, 0, 0);
  // Overnight ranges (e.g. "from 11pm to 1am") roll the end past
  // midnight onto the next day.
  if (endDate <= startDate) endDate.setDate(endDate.getDate() + 1);
  return { startDate, endDate };
}

// ----- Main parser ---------------------------------------------------

function parseQuickAdd(rawInput, opts) {
  const cfg = Object.assign({
    now:                new Date(),
    defaultDurationMin: 60,
    agendas:            [],
    defaultDate:        null,
  }, opts || {});
  const now = cfg.now;
  let work = String(rawInput || "").trim();
  if (!work) return { ok: false, name: "", error: "empty" };

  // "... to <AgendaName> ..." — route to a named agenda. The " to
  // <AgendaName>" segment can sit anywhere in the input (tail is the
  // common case, but "Coffee to Work at 9" and "Team lunch to Work
  // tomorrow" work too). The match is case-insensitive AND normalized:
  // an agenda named "Ours ✨" matches user text "to ours", "to OURS",
  // "to Ours ✨", etc. — normalization strips every non-alphanumeric
  // character (spaces, punctuation, emoji) from both sides, and
  // agenda-name-word gaps become flexible `[^a-z0-9]+` runs so
  // multi-word names like "Family Trips" match "to family trips" and
  // "to Family    Trips ✨" identically.
  //
  // Must run BEFORE the location phase — otherwise LOCATION_RE's greedy
  // "at <...>$" would swallow the "to <Agenda>" segment into a location
  // ("Coffee at Blue Bottle to Work" → location "Blue Bottle to Work").
  //
  // Longest normalized agenda name wins so "Family Trips" beats "Family"
  // when both would match. Agendas whose names contain no alphanumeric
  // characters (e.g. a pure-emoji name) can't be matched by keyboard and
  // are skipped.
  let agendaId = null;
  if (cfg.agendas.length) {
    const scored = cfg.agendas
      .map((a) => ({ agenda: a, pattern: normalizedAgendaPattern(a.name) }))
      .filter((x) => x.pattern)
      .sort((a, b) => b.pattern.normLen - a.pattern.normLen);
    for (const { agenda, pattern } of scored) {
      const re = new RegExp(`(?:^|\\s)to\\s+${pattern.regex}(?![a-z0-9])`, "i");
      const m = work.match(re);
      if (m) {
        agendaId = agenda.id;
        work = (work.slice(0, m.index) + work.slice(m.index + m[0].length))
                  .replace(/\s{2,}/g, " ").trim();
        break;
      }
    }
  }

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
      timeKnown: true, dayHint: "relative", durationKnown: false, location: relLocation, allDay: false, agendaId,
    });
  }

  // 1b. "from X to Y" / "from X until Y" — a range that sets BOTH the
  // start clock AND the duration in one shot. Detected before duration
  // and time phases so neither gobbles tokens that belong to the range.
  // Meridiem is resolved in phase 7 (after targetDate is known) so the
  // nearest-future heuristic can use the right date as its anchor.
  let pendingRange = null;
  {
    const { match, rest } = consume(work, RANGE_RE);
    if (match) {
      pendingRange = {
        startSpec: { token: match[1].toLowerCase(), ap: match[2] ? match[2][0].toLowerCase() : null },
        endSpec:   { token: match[3].toLowerCase(), ap: match[4] ? match[4][0].toLowerCase() : null },
      };
      work = rest;
    }
  }

  // 2. Duration extraction. Skipped when a from-to range matched —
  // the range defines duration, and any stray "for N min" alongside
  // would either double-count or contradict.
  let durationMin = null;
  if (!pendingRange) {
    const dur = extractDuration(work);
    if (dur.matched && dur.minutes > 0) {
      durationMin = dur.minutes;
      work = dur.rest;
    }
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

  // Skip the regular time phase when a from-to range matched — the
  // range owns both ends of the event and a stray "at 4pm" alongside
  // it would either contradict or get re-parsed as a third clock.
  if (!isAllDay && !pendingRange) {
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

  // 6. Default day if none extracted. Falls back to the caller-supplied
  // `defaultDate` (the Day/Week page's currently-viewed date) so quick
  // adds land where the user is looking instead of today. Only kicks in
  // when the viewed date differs from today — a defaultDate that equals
  // today should behave identically to no defaultDate at all, so the
  // "always future" roll below still bumps past-time events to tomorrow
  // on the today view.
  let usedDefaultDate = false;
  if (!targetDate) {
    const fallback = parseDefaultDate(cfg.defaultDate);
    if (fallback && fallback.getTime() !== startOfDay(now).getTime()) {
      targetDate = fallback;
      usedDefaultDate = true;
    } else {
      targetDate = startOfDay(now);
    }
  }

  // 7. Resolve the hour-of-day.
  let startDate;
  let endDateFromRange = null;
  if (isAllDay) {
    // All-day events anchor to midnight of the target date. No top-of-
    // hour default, no clock parse — both are intentionally ignored
    // when `all day` is in the input.
    startDate = new Date(targetDate);
    startDate.setHours(0, 0, 0, 0);
  } else if (pendingRange) {
    const resolved = resolveRange(pendingRange, targetDate, now);
    startDate = resolved.startDate;
    endDateFromRange = resolved.endDate;
    timeKnown = true;
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
    else if (meridiem == null) h24 = pickAmbiguousMeridiem(hour, minute, targetDate, now);
    startDate = new Date(targetDate);
    startDate.setHours(h24, minute, 0, 0);
  }

  // Resolve duration. All-day events default to a full day (1440 min)
  // when no `for N days/weeks` was given. From-to ranges have already
  // produced an explicit endDate — duration is just the gap.
  let endDate;
  let durMin;
  if (endDateFromRange) {
    endDate = endDateFromRange;
    durMin = Math.round((endDate.getTime() - startDate.getTime()) / 60000);
  } else {
    const defaultDur = isAllDay ? 1440 : cfg.defaultDurationMin;
    durMin = durationMin != null ? durationMin : defaultDur;
    endDate = new Date(startDate.getTime() + durMin * 60 * 1000);
  }

  // 8. ALWAYS future. Gates on the EVENT END so that an all-day event
  // for today (start at midnight = past, but the event spans the rest
  // of the day) doesn't roll forward unnecessarily. For timed events
  // this still rolls past-due times to tomorrow same-time. Skipped when
  // the target date came from the viewed-date fallback — the user is
  // explicitly looking at that date, so honoring it (even for a past
  // day / past hour) matches intent better than silently jumping the
  // event forward to today.
  if (!usedDefaultDate) {
    while (endDate <= now) {
      startDate = addDays(startDate, 1);
      endDate = addDays(endDate, 1);
    }
  }

  return successResult(name, startDate, endDate, durMin, {
    dayHint,
    timeKnown,
    durationKnown: durationMin != null || pendingRange != null,
    location,
    allDay:        isAllDay,
    agendaId,
  });
}

function successResult(name, startDate, endDate, durationMin, hints) {
  return {
    ok:          true,
    name,
    location:    hints.location || null,
    allDay:      !!hints.allDay,
    agendaId:    hints.agendaId == null ? null : hints.agendaId,
    startAt:     Math.floor(startDate.getTime() / 1000),
    endAt:       Math.floor(endDate.getTime()   / 1000),
    durationMin,
    hints:       Object.assign({ startDate, endDate }, hints),
  };
}

const AgendaQuickAddParser = { parseQuickAdd, extractDuration };

if (typeof module !== "undefined" && module.exports) module.exports = AgendaQuickAddParser;
if (typeof window !== "undefined") window.AgendaQuickAddParser = AgendaQuickAddParser;
