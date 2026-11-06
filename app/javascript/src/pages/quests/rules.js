// Quest board rules — pure functions over the board blob, no DOM. The page
// (index.js) renders and persists; everything that decides what a count is,
// whether a quest is on the board right now, and what a tap or an undo does
// lives here, so spec/javascript/quest_rules_runner.js can drive it in node.
//
// The board:
//   settings: { resetHour }            game days roll over at this hour
//   items:    [Item]                   in board order
//   counts:   { periodKey: { itemId: n } }
//   log:      [Entry]                  recent taps, newest last, for undo
//
// A count is kept per PERIOD rather than per day: a daily quest's period is
// its game day ("d:2026-11-04"), a weekly one's is the Monday that starts its
// week ("w:2026-11-02"), and a quest that never resets has one period, "all".
// A new period is a fresh zero, so nothing has to run at rollover.

const HOUR_MS = 3600 * 1000;

function pad(n) { return String(n).padStart(2, "0"); }

function dayKey(date) {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

function addDays(date, n) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + n);
}

function resetHourOf(board) {
  const h = parseInt(board?.settings?.resetHour, 10);
  return Number.isFinite(h) && h >= 0 && h < 24 ? h : 4;
}

// The game day a moment belongs to: before the reset hour it's still the
// previous day, so 1am Saturday counts toward Friday's quests.
function gameDate(now, resetHour) {
  const shifted = new Date(now.getTime() - (resetHour * HOUR_MS));
  return new Date(shifted.getFullYear(), shifted.getMonth(), shifted.getDate());
}

function periodKey(item, date) {
  switch (item?.reset) {
    case "never": return "all";
    case "weekly": {
      const monday = addDays(date, -((date.getDay() + 6) % 7));
      return `w:${dayKey(monday)}`;
    }
    default: return `d:${dayKey(date)}`;
  }
}

function findItem(board, id) {
  return (board.items || []).find(i => i.id === id) || null;
}

function countOf(board, item, date) {
  if (!item) return 0;
  return board.counts?.[periodKey(item, date)]?.[item.id] || 0;
}

function addCount(board, itemId, period, delta) {
  board.counts ||= {};
  const bucket = (board.counts[period] ||= {});
  const next = (bucket[itemId] || 0) + delta;
  if (next === 0) delete bucket[itemId];
  else bucket[itemId] = next;
  if (!Object.keys(bucket).length) delete board.counts[period];
}

// "yesterday" is the game day before `date`. For a weekly or never-resetting
// quest that is usually the same period as today.
function dateFor(date, when) {
  return when === "yesterday" ? addDays(date, -1) : date;
}

// How many times a quest needs doing. null means it's a plain counter with no
// finish line (a shovel's health). A target taken from another quest is that
// quest's count on the chosen day, times `scale`.
function resolveTarget(board, item, date) {
  const t = item?.target || {};
  if (t.mode === "none") return null;
  if (t.mode === "ref") {
    const ref = findItem(board, t.item);
    const scale = Number.isFinite(Number(t.scale)) && t.scale !== "" ? Number(t.scale) : 1;
    return Math.max(0, Math.round(countOf(board, ref, dateFor(date, t.when)) * scale));
  }
  const n = parseInt(t.value, 10);
  return Number.isFinite(n) && n > 0 ? n : 1;
}

function isDone(board, item, date) {
  const target = resolveTarget(board, item, date);
  return target != null && countOf(board, item, date) >= target;
}

function minutesOf(hhmm) {
  const m = /^(\d{1,2}):(\d{2})$/.exec(hhmm || "");
  return m ? (parseInt(m[1], 10) * 60) + parseInt(m[2], 10) : null;
}

// Days of the week and months are read off the GAME day; the time window is
// the wall clock. An open-ended window runs to (or from) the reset hour, so
// "from 18:00" means the rest of that game day, past midnight included.
function scheduleMatches(schedule, now, date, resetHour) {
  const s = schedule || {};
  if (s.days?.length && !s.days.includes(date.getDay())) return false;
  if (s.months?.length && !s.months.includes(date.getMonth() + 1)) return false;
  const key = dayKey(date);
  if (s.startDate && key < s.startDate) return false;
  if (s.endDate && key > s.endDate) return false;

  let from = minutesOf(s.from);
  let to = minutesOf(s.to);
  if (from == null && to == null) return true;
  from ??= resetHour * 60;
  to ??= resetHour * 60;
  const m = (now.getHours() * 60) + now.getMinutes();
  if (from === to) return true;
  return from < to ? (m >= from && m < to) : (m >= from || m < to);
}

function conditionPasses(board, cond, date) {
  const ref = findItem(board, cond.item);
  if (!ref) return false;
  const day = dateFor(date, cond.when);
  if (cond.op === "done") return isDone(board, ref, day);
  if (cond.op === "not_done") return !isDone(board, ref, day);

  const count = countOf(board, ref, day);
  const value = Number(cond.value) || 0;
  switch (cond.op) {
    case ">":  return count > value;
    case ">=": return count >= value;
    case "<":  return count < value;
    case "<=": return count <= value;
    case "=":  return count === value;
    case "!=": return count !== value;
    default:   return false;
  }
}

// On the board right now: in its schedule, every condition holds, and it has
// something to do — a target that works out to zero ("collect the 0 stars you
// wished on") keeps it off.
function isVisible(board, item, now) {
  const resetHour = resetHourOf(board);
  const date = gameDate(now, resetHour);
  if (!scheduleMatches(item.schedule, now, date, resetHour)) return false;
  if (!(item.conditions || []).every(c => conditionPasses(board, c, date))) return false;
  const target = resolveTarget(board, item, date);
  return target === null || target > 0;
}

// A count-down quest shows what's LEFT of its target, so a shovel reads 100
// when it's new and wears down with every hit. Underneath it counts up like
// any other quest, so done, effects, undo and reset all work unchanged.
function countsDown(item, target) {
  return !!item?.countDown && target != null;
}

function shownCount(item, count, target) {
  return countsDown(item, target) ? Math.max(0, target - count) : count;
}

function displayName(item, target) {
  return String(item?.name || "").replace(/\{n\}/g, target == null ? "" : String(target)).trim();
}

// Moves another quest's count by `amount`, held between zero and its target.
// Answers the change actually made, or null when it was already at the edge.
function shiftItem(board, item, amount, date) {
  if (!item || !amount) return null;
  const target = resolveTarget(board, item, date);
  const count = countOf(board, item, date);
  let next = count + amount;
  if (amount > 0 && target != null) next = Math.min(next, Math.max(target, count));
  if (amount < 0) next = Math.max(next, Math.min(0, count));
  const delta = next - count;
  if (!delta) return null;
  const period = periodKey(item, date);
  addCount(board, item.id, period, delta);
  return { item: item.id, period, delta };
}

function newId(prefix) {
  const rand = (typeof crypto !== "undefined" && crypto.randomUUID)
    ? crypto.randomUUID().slice(0, 8)
    : Math.random().toString(36).slice(2, 10);
  return `${prefix}${rand}`;
}

// One tap (or `times` taps from multi mode) on a quest. Mutates the board and
// answers the log entry, or null when there was nothing to do — a finished
// quest doesn't count past its target.
//
// Effects and hooks marked `on: "tap"` fire for the tap; `on: "complete"` fire
// only for the tap that reaches the target. Effects don't chain: a rock adding
// to the shovel doesn't run the shovel's own effects.
function tap(board, item, now, times = 1) {
  const date = gameDate(now, resetHourOf(board));
  const target = resolveTarget(board, item, date);
  const count = countOf(board, item, date);
  const step = Math.max(1, parseInt(item.step, 10) || 1);
  let delta = step * Math.max(1, times);
  if (target != null) {
    if (count >= target) return null;
    delta = Math.min(delta, target - count);
  }

  const period = periodKey(item, date);
  addCount(board, item.id, period, delta);
  const changes = [{ item: item.id, period, delta }];
  const completed = target != null && count < target && (count + delta) >= target;
  const fires = on => on === "tap" || (on === "complete" && completed);

  (item.effects || []).forEach(effect => {
    if (!fires(effect.on)) return;
    const amount = (Number(effect.amount) || 0) * (effect.on === "tap" ? Math.max(1, times) : 1);
    const change = shiftItem(board, findItem(board, effect.item), amount, date);
    if (change) changes.push(change);
  });

  const after = count + delta;
  const hooks = (item.hooks || []).filter(h => fires(h.on)).map(h => ({
    kind:    h.kind,
    name:    h.name || "",
    notes:   String(h.notes || "").replace(/\{n\}/g, String(after)),
    trigger: h.trigger || "",
    data:    {
      quest: displayName(item, target), count: after, target,
      times: Math.max(1, times), action: completed ? "complete" : "tap",
    },
    state:   "pending",
  }));

  const entry = { id: newId("e"), item: item.id, at: now.getTime(), changes, hooks };
  (board.log ||= []).push(entry);
  return entry;
}

// Sets a quest back to zero for its current period (the shovel's "until I
// reset it"). Logged like a tap, so a hold walks it back.
function resetItem(board, item, now) {
  const date = gameDate(now, resetHourOf(board));
  const count = countOf(board, item, date);
  if (!count) return null;
  const period = periodKey(item, date);
  addCount(board, item.id, period, -count);
  const entry = { id: newId("e"), item: item.id, at: now.getTime(), changes: [{ item: item.id, period, delta: -count }], hooks: [], reset: true };
  (board.log ||= []).push(entry);
  return entry;
}

// Walks back the newest thing done to this quest in its current period —
// its own count and every effect that tap had on other quests. Answers the
// entry, so the page can take back the hooks it fired.
function undo(board, item, now) {
  const date = gameDate(now, resetHourOf(board));
  const period = periodKey(item, date);
  const log = board.log || [];
  for (let i = log.length - 1; i >= 0; i--) {
    const entry = log[i];
    if (entry.undone || entry.item !== item.id) continue;
    if (entry.changes?.[0]?.period !== period) continue;
    entry.changes.forEach(c => addCount(board, c.item, c.period, -c.delta));
    entry.undone = true;
    return entry;
  }
  return null;
}

// Counts are kept long enough for "yesterday" and a little history; the log
// only needs to reach back as far as anyone would hold to undo.
function prune(board, now) {
  const today = gameDate(now, resetHourOf(board));
  const dayCut = `d:${dayKey(addDays(today, -60))}`;
  const weekCut = `w:${dayKey(addDays(today, -70))}`;
  Object.keys(board.counts || {}).forEach(k => {
    if ((k.startsWith("d:") && k < dayCut) || (k.startsWith("w:") && k < weekCut)) delete board.counts[k];
  });
  const logCut = now.getTime() - (4 * 24 * HOUR_MS);
  board.log = (board.log || []).filter(e => e.at >= logCut).slice(-500);
}

// "Wish on 20 stars" → a quest done 20 times, named "Wish on {n} stars" so the
// number on the circle follows the target if it's changed later.
function parseQuickAdd(text) {
  const raw = String(text || "").trim();
  const m = /\d+/.exec(raw);
  if (!m) return { name: raw, target: 1 };
  const target = Math.max(1, parseInt(m[0], 10));
  const name = `${raw.slice(0, m.index)}{n}${raw.slice(m.index + m[0].length)}`;
  return { name, target };
}

function newItem(attrs = {}) {
  return {
    id:         newId("q"),
    name:       "",
    icon:       "",
    section:    "",
    target:     { mode: "fixed", value: 1 },
    step:       1,
    reset:      "daily",
    schedule:   { days: [], months: [], startDate: "", endDate: "", from: "", to: "" },
    conditions: [],
    effects:    [],
    hooks:      [],
    ...attrs,
  };
}

const QuestRules = {
  dayKey, addDays, gameDate, periodKey, resetHourOf, findItem, countOf,
  resolveTarget, isDone, scheduleMatches, conditionPasses, isVisible,
  countsDown, shownCount, displayName, tap, resetItem, undo, prune, parseQuickAdd, newItem,
};

if (typeof module !== "undefined" && module.exports) module.exports = QuestRules;
if (typeof window !== "undefined") window.QuestRules = QuestRules;
