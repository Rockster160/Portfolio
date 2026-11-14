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
//   sections: [{ id, name }]           section order; quests name theirs
//   autoFired: { itemId: Entry }       what a batch quest last fired, by period
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
  if (isAuto(item)) return autoState(board, item, date).count;
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
  if (t.mode === "auto") return autoState(board, item, date).target;
  if (t.mode === "ref") {
    const ref = findItem(board, t.item);
    const scale = Number.isFinite(Number(t.scale)) && t.scale !== "" ? Number(t.scale) : 1;
    return Math.max(0, Math.round(countOf(board, ref, dateFor(date, t.when)) * scale));
  }
  const n = parseInt(t.value, 10);
  return Number.isFinite(n) && n > 0 ? n : 1;
}

function isDone(board, item, date) {
  if (isAuto(item)) return autoState(board, item, date).done;
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
function scheduleMatchesDay(schedule, date) {
  const s = schedule || {};
  if (s.days?.length && !s.days.includes(date.getDay())) return false;
  if (s.months?.length && !s.months.includes(date.getMonth() + 1)) return false;
  const key = dayKey(date);
  if (s.startDate && key < s.startDate) return false;
  if (s.endDate && key > s.endDate) return false;
  return true;
}

function scheduleMatches(schedule, now, date, resetHour) {
  if (!scheduleMatchesDay(schedule, date)) return false;
  const s = schedule || {};
  let from = minutesOf(s.from);
  let to = minutesOf(s.to);
  if (from == null && to == null) return true;
  from ??= resetHour * 60;
  to ??= resetHour * 60;
  const m = (now.getHours() * 60) + now.getMinutes();
  if (from === to) return true;
  return from < to ? (m >= from && m < to) : (m >= from || m < to);
}

// A rotation's options, and who came on a day: the recorded main pick (or the
// option whose fixed day it is) plus any extras. rotation.js builds the week
// on these; a condition asks them whether a visitor is here.
function findOption(item, id) {
  return (item?.options || []).find(o => o.id === id) || null;
}

function fixedDay(option) {
  const day = parseInt(option?.day, 10);
  return option?.slot !== "extra" && day >= 0 && day <= 6 ? day : null;
}

function rotationEntry(board, item, date) {
  return board.rotations?.[item.id]?.[dayKey(date)] || null;
}

function mainOn(board, item, date) {
  const main = rotationEntry(board, item, date)?.main;
  if (main && findOption(item, main)) return main;
  return (item.options || []).find(o => fixedDay(o) === date.getDay())?.id || null;
}

function extrasOn(board, item, date) {
  return (rotationEntry(board, item, date)?.extras || []).filter(id => findOption(item, id));
}

function isHere(board, item, date, optionId) {
  return mainOn(board, item, date) === optionId || extrasOn(board, item, date).includes(optionId);
}

// A quest waiting on a visitor who's no longer in the rotation would never
// show again, so the condition goes with the visitor.
function dropMissingVisitors(board) {
  (board.items || []).forEach(item => {
    if (!item.conditions?.length) return;
    item.conditions = item.conditions.filter(c => {
      return !c.option || !!findOption(findItem(board, c.item), c.option);
    });
  });
}

function conditionPasses(board, cond, date) {
  const ref = findItem(board, cond.item);
  if (!ref) return false;
  const day = dateFor(date, cond.when);
  if (cond.option) {
    if (ref.kind !== "rotation" || !findOption(ref, cond.option)) return false;
    const here = isHere(board, ref, day, cond.option);
    return cond.op === "not_here" ? !here : here;
  }
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

// A batch quest ("When others are") counts itself: each of its rows is a
// condition like "Only when" uses, and it's done when all of them, any of
// them, or at least `n` of them hold. A row about a quest that isn't on that
// day's board at all (its days, months, dates or conditions rule it out) is
// left out, so "all of these talks" means everyone who is actually around. No
// rows left means nothing to do: a target of 0, off the board.
// A locked quest is never counted from the board — no tap, no ×N, no hold —
// while effects, auto rules and the editor still move it.
function isLocked(item) {
  return !!item?.locked;
}

function isAuto(item) {
  return item?.target?.mode === "auto";
}

// Quests reading each other through batch rows could go round in a circle;
// one already being worked out counts as nothing done.
const evaluating = new Set();

function onBoardThatDay(board, item, date) {
  if (!item) return false;
  if (item.kind === "rotation") return true;
  if (!scheduleMatchesDay(item.schedule, date)) return false;
  return (item.conditions || []).every(c => conditionPasses(board, c, date));
}

function autoState(board, item, date) {
  if (evaluating.has(item.id)) return { count: 0, target: 0, done: false };
  evaluating.add(item.id);
  try {
    const t = item.target;
    const rows = (t.conditions || []).filter(c => {
      return c.option || onBoardThatDay(board, findItem(board, c.item), dateFor(date, c.when));
    });
    if (!rows.length) return { count: 0, target: 0, done: false };
    const passed = rows.filter(c => conditionPasses(board, c, date)).length;
    let target = rows.length;
    if (t.match === "any") target = 1;
    if (t.match === "atLeast") target = Math.min(rows.length, Math.max(1, parseInt(t.n, 10) || 1));
    return { count: Math.min(passed, target), target, done: passed >= target };
  } finally {
    evaluating.delete(item.id);
  }
}

// On the board right now: not hidden, in its schedule, every condition holds,
// and it has something to do — a target that works out to zero ("collect the
// 0 stars you wished on") keeps it off.
//
// A hidden quest is never drawn in play, only in edit mode. Everything else
// about it is untouched: its count moves under other quests' effects, a batch
// quest finishes and fires on its own, and rows and conditions that read it
// treat it as on the board — it's off the page, not off the day.
function isVisible(board, item, now) {
  if (item?.hidden) return false;
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
  if (!item || !amount || isAuto(item)) return null;
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

function hookFor(hook, item, count, target, times, action) {
  return {
    kind:    hook.kind,
    name:    hook.name || "",
    notes:   String(hook.notes || "").replace(/\{n\}/g, String(count)),
    trigger: hook.trigger || "",
    data:    { quest: displayName(item, target), count, target, times: Math.max(1, times), action },
    state:   "pending",
  };
}

function newId(prefix) {
  const rand = (typeof crypto !== "undefined" && crypto.randomUUID)
    ? crypto.randomUUID().slice(0, 8)
    : Math.random().toString(36).slice(2, 10);
  return `${prefix}${rand}`;
}

// One tap (or `times` taps from multi mode) on a quest. Mutates the board and
// answers the log entry, or null when there was nothing to do — a finished
// quest doesn't count past its target, and a locked one isn't tapped at all.
//
// Effects and hooks marked `on: "tap"` fire for the tap; `on: "complete"` fire
// only for the tap that reaches the target. Effects don't chain: a rock adding
// to the shovel doesn't run the shovel's own effects.
function tap(board, item, now, times = 1) {
  if (isAuto(item) || isLocked(item)) return null;
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
  const action = completed ? "complete" : "tap";
  const hooks = (item.hooks || []).filter(h => fires(h.on)).map(h => {
    return hookFor(h, item, after, target, times, action);
  });

  const entry = { id: newId("e"), item: item.id, at: now.getTime(), changes, hooks };
  (board.log ||= []).push(entry);
  return entry;
}

// Sets a quest back to zero for its current period (the shovel's "until I
// reset it"). Logged like a tap, so a hold walks it back.
function resetItem(board, item, now) {
  if (isAuto(item)) return null;
  const date = gameDate(now, resetHourOf(board));
  const count = countOf(board, item, date);
  if (!count) return null;
  const period = periodKey(item, date);
  addCount(board, item.id, period, -count);
  const entry = { id: newId("e"), item: item.id, at: now.getTime(), changes: [{ item: item.id, period, delta: -count }], hooks: [], reset: true };
  (board.log ||= []).push(entry);
  return entry;
}

// Puts a quest straight at a number — the one shown on its circle, so a
// count-down shovel showing 100 is set to 90 by typing 90. Held between zero
// and its target, logged like a tap so a hold walks it back, and fires
// nothing: it's a correction, not a round of taps.
function setCount(board, item, now, shown) {
  if (!item || isAuto(item)) return null;
  const date = gameDate(now, resetHourOf(board));
  const target = resolveTarget(board, item, date);
  const wanted = Math.round(Number(shown));
  if (!Number.isFinite(wanted)) return null;
  let value = Math.max(0, countsDown(item, target) ? target - wanted : wanted);
  if (target != null) value = Math.min(value, target);
  const delta = value - countOf(board, item, date);
  if (!delta) return null;
  const period = periodKey(item, date);
  addCount(board, item.id, period, delta);
  const entry = { id: newId("e"), item: item.id, at: now.getTime(), changes: [{ item: item.id, period, delta }], hooks: [], set: true };
  (board.log ||= []).push(entry);
  return entry;
}

// Fires each batch quest that has become done this period and takes back one
// that no longer is (a talk under it undone). A batch quest's effects and
// hooks all fire on finishing, once a period. It runs to a standstill, since
// one batch quest's effect can finish another. Answers both lists so the page
// can send and reverse their hooks.
function settleAuto(board, now) {
  const date = gameDate(now, resetHourOf(board));
  const fired = [];
  const reversed = [];
  for (let pass = 0; pass < 5; pass++) {
    let moved = false;
    (board.items || []).filter(isAuto).forEach(item => {
      const period = periodKey(item, date);
      const last = board.autoFired?.[item.id];
      const live = last && !last.undone && last.period === period;
      const done = isDone(board, item, date);
      if (done && !live) {
        fired.push(fireAuto(board, item, date, period, now));
        moved = true;
      } else if (!done && live) {
        last.changes.forEach(c => addCount(board, c.item, c.period, -c.delta));
        last.undone = true;
        reversed.push(last);
        moved = true;
      }
    });
    if (!moved) break;
  }
  return { fired, reversed };
}

function fireAuto(board, item, date, period, now) {
  const { count, target } = autoState(board, item, date);
  const changes = [];
  (item.effects || []).forEach(effect => {
    const change = shiftItem(board, findItem(board, effect.item), Number(effect.amount) || 0, date);
    if (change) changes.push(change);
  });
  const hooks = (item.hooks || []).map(h => hookFor(h, item, count, target, 1, "complete"));
  const entry = { id: newId("e"), item: item.id, at: now.getTime(), period, changes, hooks, auto: true };
  (board.autoFired ||= {})[item.id] = entry;
  return entry;
}

// Sections in board order: the board's own list, then any name a quest
// carries that the list doesn't have yet (in the order those quests sit).
function sectionNames(board) {
  const names = (board.sections || []).map(s => s.name).filter(Boolean);
  (board.items || []).forEach(i => {
    if (i.section && !names.includes(i.section)) names.push(i.section);
  });
  return names;
}

function syncSections(board) {
  const known = new Set((board.sections || []).map(s => s.name));
  const missing = sectionNames(board).filter(n => !known.has(n));
  if (board.sections && !missing.length) return;
  board.sections = [...(board.sections || []), ...missing.map(name => ({ id: newId("s"), name }))];
}

// Takes the section list as edited in settings, in its new order. A renamed
// section takes its quests with it; a removed one leaves them in no section.
function setSections(board, rows) {
  const old = new Map((board.sections || []).map(s => [s.id, s.name]));
  const moves = new Map();
  const next = [];
  rows.forEach(({ id, name }) => {
    const clean = String(name || "").trim();
    if (old.has(id) && old.get(id) !== clean) moves.set(old.get(id), clean);
    if (clean && !next.some(s => s.name === clean)) next.push({ id: id || newId("s"), name: clean });
  });
  old.forEach((name, id) => {
    if (!rows.some(r => r.id === id)) moves.set(name, "");
  });
  (board.items || []).forEach(item => {
    if (item.section && moves.has(item.section)) item.section = moves.get(item.section);
  });
  board.sections = next;
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
  const live = new Set((board.items || []).map(i => i.id));
  Object.keys(board.autoFired || {}).forEach(id => { if (!live.has(id)) delete board.autoFired[id]; });
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
  resolveTarget, isDone, findOption, fixedDay, rotationEntry, mainOn, extrasOn, isHere,
  dropMissingVisitors, scheduleMatches, conditionPasses, isVisible, isAuto, isLocked,
  autoState,
  countsDown, shownCount, displayName, tap, resetItem, setCount, settleAuto, undo, prune,
  sectionNames, syncSections, setSections, parseQuickAdd, newItem, newId,
};

if (typeof module !== "undefined" && module.exports) module.exports = QuestRules;
if (typeof window !== "undefined") window.QuestRules = QuestRules;
