// Rotation quests — pure functions over the board blob, no DOM, so
// spec/javascript/quest_rotation_runner.js can drive them in node.
//
// A rotation is a set of options that come around: each game day has at most
// one MAIN pick and any number of EXTRAS. A main option comes at most once a
// week (Monday to Sunday, matching the weekly quests), so one already picked
// this week isn't expected again; one that wasn't picked at all last week is
// DUE. An option with a fixed day is that day's pick unless another was
// recorded, and is never due. An extra can turn up on any day alongside the
// main pick.
//
// The item:
//   { kind: "rotation", name, icon, section,
//     options: [{ id, name, icon, slot: "main" | "extra", day: null | 0-6 }] }
// What was picked:
//   board.rotations: { itemId: { "2026-11-09": { main: optionId, extras: [optionId] } } }

import QuestRules from "./rules";

function isRotation(item) {
  return item?.kind === "rotation";
}

function findOption(item, id) {
  return (item?.options || []).find(o => o.id === id) || null;
}

function isExtra(option) {
  return option?.slot === "extra";
}

function fixedDay(option) {
  const day = parseInt(option?.day, 10);
  return !isExtra(option) && day >= 0 && day <= 6 ? day : null;
}

function mondayOf(date) {
  return QuestRules.addDays(date, -((date.getDay() + 6) % 7));
}

function weekDays(date) {
  const monday = mondayOf(date);
  return Array.from({ length: 7 }, (_, i) => QuestRules.addDays(monday, i));
}

function recorded(board, item, date) {
  return board.rotations?.[item.id]?.[QuestRules.dayKey(date)] || null;
}

// What was (or, for a fixed day, will be) the main pick on a day.
function mainOn(board, item, date) {
  const main = recorded(board, item, date)?.main;
  if (main && findOption(item, main)) return main;
  return (item.options || []).find(o => fixedDay(o) === date.getDay())?.id || null;
}

function extrasOn(board, item, date) {
  return (recorded(board, item, date)?.extras || []).filter(id => findOption(item, id));
}

function pickedInWeek(board, item, date) {
  const picked = new Set();
  weekDays(date).forEach(day => {
    const main = mainOn(board, item, day);
    if (main) picked.add(main);
    extrasOn(board, item, day).forEach(id => picked.add(id));
  });
  return picked;
}

// Every option with where it stands in the week holding `date`.
function standings(board, item, date) {
  const thisWeek = pickedInWeek(board, item, date);
  const lastWeek = pickedInWeek(board, item, QuestRules.addDays(mondayOf(date), -7));
  return (item.options || []).map(option => ({
    ...option,
    picked: thisWeek.has(option.id),
    due:    !isExtra(option) && fixedDay(option) == null && !thisWeek.has(option.id) && !lastWeek.has(option.id),
  }));
}

function store(board, item, date, entry) {
  const key = QuestRules.dayKey(date);
  board.rotations ||= {};
  const days = (board.rotations[item.id] ||= {});
  if (entry.main || entry.extras.length) days[key] = entry;
  else delete days[key];
  if (!Object.keys(days).length) delete board.rotations[item.id];
}

// Tapping an option on a day: a main option becomes that day's pick, or stops
// being it when tapped again; an extra is added or taken off.
function toggle(board, item, date, optionId) {
  const option = findOption(item, optionId);
  if (!option) return false;
  const current = recorded(board, item, date) || {};
  const entry = { main: current.main || null, extras: [...(current.extras || [])] };
  if (isExtra(option)) {
    entry.extras = entry.extras.includes(optionId)
      ? entry.extras.filter(id => id !== optionId)
      : [...entry.extras, optionId];
  } else {
    entry.main = mainOn(board, item, date) === optionId ? null : optionId;
  }
  store(board, item, date, entry);
  return true;
}

// Two weeks is all "due" needs; the rest is kept as long as counts are, and a
// deleted rotation's picks go with it.
function prune(board, today) {
  const cut = QuestRules.dayKey(QuestRules.addDays(today, -60));
  const live = new Set((board.items || []).filter(isRotation).map(i => i.id));
  Object.keys(board.rotations || {}).forEach(itemId => {
    if (!live.has(itemId)) { delete board.rotations[itemId]; return; }
    const days = board.rotations[itemId];
    Object.keys(days).forEach(k => { if (k < cut) delete days[k]; });
    if (!Object.keys(days).length) delete board.rotations[itemId];
  });
}

function newRotation(attrs = {}) {
  return { id: QuestRules.newId("q"), kind: "rotation", name: "", icon: "", section: "", options: [], ...attrs };
}

function newOption(attrs = {}) {
  return { id: QuestRules.newId("o"), name: "", icon: "", slot: "main", day: null, ...attrs };
}

const QuestRotation = {
  isRotation, findOption, isExtra, fixedDay, weekDays, mainOn, extrasOn, standings, toggle, prune,
  newRotation, newOption,
};

export default QuestRotation;
