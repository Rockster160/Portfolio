// How a chore is searched for by name, everywhere one is picked: the Chores
// page's search box and pickers, and a board's pin and credit-button pickers.
// A chore's name counts fully, each of its aliases for half; within a field a
// prefix beats an infix beats letters-in-order. 0 is no match.
//
// The Chores page script is an inline module, so it reads this off
// `window.ChoreSearch`; bundled code imports it.

function fuzzyMatch(needle, hay) {
  let i = 0;
  let j = 0;
  while (i < needle.length && j < hay.length) {
    if (needle[i] === hay[j]) i++;
    j++;
  }
  return i === needle.length;
}

export function score(needle, name, aliases) {
  if (!needle) return 1;
  const n = needle.toLowerCase();
  const fields = [
    { text: (name || "").toLowerCase(), weight: 1.0 },
    ...(aliases || []).map((a) => ({ text: String(a).toLowerCase(), weight: 0.5 })),
  ];
  let best = 0;
  for (const { text, weight } of fields) {
    if (!text) continue;
    const idx = text.indexOf(n);
    let local = 0;
    if (idx === 0) local = 1.0;
    else if (idx > 0) local = 0.7 - Math.min(idx, 10) * 0.02;
    else if (fuzzyMatch(n, text)) local = 0.3;
    else continue;
    best = Math.max(best, local * weight);
  }
  return best;
}

// ---- Fields ----
// The box also reads the field syntax the History filter and Jil listeners
// use: `group:home`, `nick::Trash`, `due<2026-11-01`, `reward>=5`, `-is:done`,
// quoted values (`group:"Front yard"`) and `OR` between runs of terms. Every
// term in a run has to hold. Bare words are the name search above, against
// the short name and aliases; `name:` reaches the full name.
//
//   :   contains (exact for dates, numbers and `is:`)    ::  =  exact
//   > < >= <=  compare dates and numbers
//
// Dates take an ISO day, today / tomorrow / yesterday, or an offset in days
// (`+3`, `-2`). `none` matches a field with nothing in it, and `due:overdue`
// is anything due before today.
const TEXT_FIELDS = {
  name:     (c) => [c.name],
  nick:     (c) => [c.short_name],
  alias:    (c) => c.aliases || [],
  group:    (c) => c.tags || [],
  notes:    (c) => [c.notes],
  priority: (c) => [c.priority],
  for:      (c, ctx) => [ctx.users?.[c.assigned_to_user_id]],
  by:       (c) => [c.last_actor_username],
};
const DATE_FIELDS = {
  due:  (c) => c.marked_due_on || c.scheduled_due_on || null,
  done: (c) => (c.last_completed_at ? localIso(new Date(c.last_completed_at)) : null),
};
const NUMBER_FIELDS = {
  reward: (c) => c.reward_pebbles,
  target: (c) => c.target_count,
  count:  (c) => c.done_count_today,
};
const FLAGS = {
  due:       (c) => !!c.due_today,
  today:     (c) => !!c.today_visible,
  done:      (c) => (c.done_count_today || 0) > 0,
  hot:       (c) => c.hot_multiplier != null,
  dismissed: (c) => !!c.dismissed,
  skipped:   (c) => !!c.skipped_today,
  oneoff:    (c) => !!c.one_off,
  daily:     (c) => !!c.on_dailies,
  sub:       (c) => !!c.parent_chore_id,
  assigned:  (c) => !!c.assigned_to_user_id,
  grouped:   (c) => (c.tags || []).length > 0,
  overdue:   (c, ctx) => {
    const due = DATE_FIELDS.due(c);
    return !!due && due < ctx.today;
  },
};
const FIELD_ALIASES = {
  short: "nick", nickname: "nick", aliases: "alias", aka: "alias",
  tag: "group", tags: "group", groups: "group", in: "group",
  note: "notes", pri: "priority", assigned: "for", who: "for",
  last: "by", pebbles: "reward", has: "is",
};
const TERM_RX = /^(-?)([a-z_]+)(::|>=|<=|:|>|<|=)(.+)$/i;

function localIso(d) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

function knownField(name) {
  return name === "is" || name in TEXT_FIELDS || name in DATE_FIELDS || name in NUMBER_FIELDS;
}

// Whitespace splits terms except inside quotes, which are dropped.
function splitTerms(query) {
  const out = [];
  let cur = "";
  let quoted = false;
  for (const ch of String(query || "")) {
    if (ch === "\"") { quoted = !quoted; continue; }
    if (!quoted && /\s/.test(ch)) {
      if (cur) out.push(cur);
      cur = "";
      continue;
    }
    cur += ch;
  }
  if (cur) out.push(cur);
  return out;
}

// [[term, ...], ...] - one inner list per side of an OR. A term is
// { negate, field, op, value } or { negate, word }. Something that looks like
// a field but names none ("10:30") stays a word.
export function parseQuery(query) {
  const runs = [[]];
  for (const raw of splitTerms(query)) {
    if (raw === "OR") { runs.push([]); continue; }
    const m = raw.match(TERM_RX);
    const field = m && (FIELD_ALIASES[m[2].toLowerCase()] || m[2].toLowerCase());
    if (m && knownField(field)) {
      runs[runs.length - 1].push({ negate: m[1] === "-", field, op: m[3], value: m[4] });
    } else {
      const negate = raw.length > 1 && raw.startsWith("-");
      runs[runs.length - 1].push({ negate, word: negate ? raw.slice(1) : raw });
    }
  }
  return runs.filter((run) => run.length);
}

function dateValue(raw, ctx) {
  const v = raw.toLowerCase();
  const offset = (days) => {
    const d = new Date(`${ctx.today}T12:00:00`);
    d.setDate(d.getDate() + days);
    return localIso(d);
  };
  if (v === "today") return ctx.today;
  if (v === "tomorrow") return offset(1);
  if (v === "yesterday") return offset(-1);
  if (/^[+-]\d+$/.test(v)) return offset(parseInt(v, 10));
  if (/^\d{4}-\d{2}-\d{2}$/.test(v)) return v;
  return null;
}

function compare(have, op, want) {
  switch (op) {
    case ">":  return have > want;
    case "<":  return have < want;
    case ">=": return have >= want;
    case "<=": return have <= want;
    default:   return have === want;
  }
}

function fieldHolds(chore, { field, op, value }, ctx) {
  const v = value.toLowerCase();
  if (field === "is") return !!FLAGS[v]?.(chore, ctx);

  if (field in TEXT_FIELDS) {
    const texts = TEXT_FIELDS[field](chore, ctx).filter(Boolean).map((t) => String(t).toLowerCase());
    if (v === "none") return texts.length === 0;
    if (op === "::" || op === "=") return texts.includes(v);
    return texts.some((t) => t.includes(v));
  }

  if (field in DATE_FIELDS) {
    const have = DATE_FIELDS[field](chore);
    if (v === "none") return !have;
    if (v === "any") return !!have;
    if (field === "due" && v === "overdue") return FLAGS.overdue(chore, ctx);
    const want = dateValue(value, ctx);
    return !!have && !!want && compare(have, op, want);
  }

  const have = Number(NUMBER_FIELDS[field](chore));
  const want = Number(value);
  return Number.isFinite(have) && Number.isFinite(want) && compare(have, op, want);
}

// 0 when the chore doesn't match. Otherwise the name score of its bare words
// (the run read as one phrase first, then word by word), or 1 when only
// fields were given. `ctx` is { today: "YYYY-MM-DD", users: { id: username } }.
export function queryScore(chore, query, ctx = {}) {
  const runs = parseQuery(query);
  if (!runs.length) return 1;
  const fullCtx = { today: localIso(new Date()), users: {}, ...ctx };
  const nameScore = (needle) => score(needle, chore.short_name || chore.name, chore.aliases || []);

  let best = 0;
  for (const run of runs) {
    if (!run.every((t) => t.word !== undefined || fieldHolds(chore, t, fullCtx) !== t.negate)) continue;
    if (!run.every((t) => !t.word || !t.negate || nameScore(t.word) === 0)) continue;

    const words = run.filter((t) => t.word && !t.negate).map((t) => t.word);
    let s = 1;
    if (words.length) {
      s = nameScore(words.join(" "));
      if (s === 0) {
        const each = words.map(nameScore);
        s = each.every((x) => x > 0) ? Math.min(...each) : 0;
      }
    }
    best = Math.max(best, s);
  }
  return best;
}

// The chores matching `query`, best first, ties by name.
export function searchChores(chores, query, ctx = {}) {
  const q = String(query || "").trim();
  return (chores || [])
    .map((c) => ({ c, s: queryScore(c, q, ctx) }))
    .filter((x) => x.s > 0)
    .sort((a, b) => b.s - a.s || String(a.c.name || "").localeCompare(String(b.c.name || "")))
    .map((x) => x.c);
}

if (typeof window !== "undefined") window.ChoreSearch = { score, queryScore, parseQuery, searchChores };
