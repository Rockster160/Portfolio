// Drives the quest board rules through the board's real uses — wishes that
// become tomorrow's collecting, a shovel whose health outlives the day and is
// topped up by rocks, a quest that only exists in November — and prints JSON
// for quest_rules_spec.rb.

const path = require("path");

const Q = require(path.resolve(
  __dirname, "..", "..", "app", "javascript", "src", "pages", "quests", "rules.js",
));

// Local wall-clock times; the board's reset hour is 4am.
const at = (y, mo, d, h = 12, mi = 0) => new Date(y, mo - 1, d, h, mi);
const NOV3 = at(2026, 11, 3, 21);
const NOV4 = at(2026, 11, 4, 12);

function board() {
  const wish = Q.newItem({ id: "wish", ...Q.parseQuickAdd("Wish on 20 stars") });
  wish.target = { mode: "fixed", value: Q.parseQuickAdd("Wish on 20 stars").target };
  const collect = Q.newItem({
    id: "collect", name: "Collect {n} stars", target: { mode: "ref", item: "wish", when: "yesterday" },
  });
  const shovel = Q.newItem({ id: "shovel", name: "Shovel", reset: "never", target: { mode: "none" } });
  const rock = Q.newItem({
    id: "rock", name: "Rock", target: { mode: "none" },
    effects: [{ on: "tap", kind: "add", item: "shovel", amount: 8 }],
    hooks: [{ on: "tap", kind: "event", name: "Rock", notes: "rock {n}" }],
  });
  const mushrooms = Q.newItem({
    id: "mush", name: "Collect {n} mushrooms", target: { mode: "fixed", value: 5 },
    schedule: { days: [], months: [11], startDate: "", endDate: "", from: "", to: "" },
    hooks: [{ on: "complete", kind: "trigger", trigger: "mushrooms_done" }],
  });
  return { settings: { resetHour: 4 }, items: [wish, collect, shovel, rock, mushrooms], counts: {}, log: [] };
}

const cases = {};
const visibleIds = (b, now) => b.items.filter(i => Q.isVisible(b, i, now)).map(i => i.id);

// Quick add pulls the number out as the target and leaves {n} in its place.
cases.quick_add = Q.parseQuickAdd("Wish on 20 stars");
cases.quick_add_plain = Q.parseQuickAdd("Feed the cat");

// Game day: 1:30am still belongs to the previous day.
cases.game_day_before_reset = Q.dayKey(Q.gameDate(at(2026, 11, 5, 1, 30), 4));
cases.game_day_after_reset = Q.dayKey(Q.gameDate(at(2026, 11, 5, 4, 0), 4));

// Stars: no wishes yesterday → no collecting today.
{
  const b = board();
  cases.stars_none = visibleIds(b, NOV4);

  // Wish on 14 stars at 9pm on the 3rd, and 2 more after midnight (still the 3rd).
  const wish = Q.findItem(b, "wish");
  Q.tap(b, wish, NOV3, 14);
  Q.tap(b, wish, at(2026, 11, 4, 1), 2);
  cases.stars_wished = Q.countOf(b, wish, Q.gameDate(NOV3, 4));
  const collect = Q.findItem(b, "collect");
  const nov4 = Q.gameDate(NOV4, 4);
  cases.stars_next_day = {
    visible: visibleIds(b, NOV4),
    target:  Q.resolveTarget(b, collect, nov4),
    name:    Q.displayName(collect, Q.resolveTarget(b, collect, nov4)),
    wishes_reset: Q.countOf(b, wish, nov4),
  };

  // Collecting stops at the target.
  Q.tap(b, collect, NOV4, 99);
  cases.stars_capped = { count: Q.countOf(b, collect, nov4), again: Q.tap(b, collect, NOV4) };
}

// Wishing caps at 20 and the 20th tap is the one that completes.
{
  const b = board();
  const wish = Q.findItem(b, "wish");
  Q.tap(b, wish, NOV4, 19);
  cases.wish_19_done = Q.isDone(b, wish, Q.gameDate(NOV4, 4));
  Q.tap(b, wish, NOV4);
  cases.wish_20_done = Q.isDone(b, wish, Q.gameDate(NOV4, 4));
}

// Shovel and rock: the rock adds 8 to a shovel that never resets; holding the
// rock takes its 8 back; a reset zeroes the shovel and is itself undoable.
{
  const b = board();
  const shovel = Q.findItem(b, "shovel");
  const rock = Q.findItem(b, "rock");
  const rockEntry = Q.tap(b, rock, NOV3);
  Q.tap(b, rock, NOV3);
  Q.tap(b, shovel, NOV3);
  const nov4 = Q.gameDate(NOV4, 4);
  cases.shovel = {
    next_day:   Q.countOf(b, shovel, nov4),
    rock_today: Q.countOf(b, rock, nov4),
    hook:       rockEntry.hooks[0],
  };

  Q.tap(b, rock, NOV4);
  const undone = Q.undo(b, rock, NOV4);
  cases.shovel.after_rock_undo = Q.countOf(b, shovel, nov4);
  cases.shovel.undone_hooks = undone.hooks.length;
  // Yesterday's rock taps are a closed period — nothing left to undo today.
  cases.shovel.second_rock_undo = Q.undo(b, rock, NOV4);

  // Holding the shovel takes back its own tap, not the rock's 8s.
  Q.undo(b, shovel, NOV4);
  cases.shovel.after_shovel_undo = Q.countOf(b, shovel, nov4);

  Q.resetItem(b, shovel, NOV4);
  cases.shovel.after_reset = Q.countOf(b, shovel, nov4);
  Q.undo(b, shovel, NOV4);
  cases.shovel.after_reset_undo = Q.countOf(b, shovel, nov4);
}

// Mushrooms: daily, November only; the trigger fires on the completing tap.
{
  const b = board();
  const mush = Q.findItem(b, "mush");
  cases.mush_october = Q.isVisible(b, mush, at(2026, 10, 31, 12));
  cases.mush_november = Q.isVisible(b, mush, NOV4);
  // 2am on Dec 1 is still Nov 30's game day.
  cases.mush_dec1_2am = Q.isVisible(b, mush, at(2026, 12, 1, 2));
  const first = Q.tap(b, mush, NOV4, 4);
  const last = Q.tap(b, mush, NOV4);
  cases.mush_hooks = { first: first.hooks.length, last: last.hooks.map(h => [h.trigger, h.data.action]) };
  cases.mush_tomorrow = Q.countOf(b, mush, Q.gameDate(at(2026, 11, 5, 12), 4));
}

// Time windows and days of the week.
{
  const night = { days: [], months: [], startDate: "", endDate: "", from: "18:00", to: "" };
  cases.window_evening = Q.scheduleMatches(night, at(2026, 11, 4, 19), Q.gameDate(at(2026, 11, 4, 19), 4), 4);
  cases.window_after_midnight = Q.scheduleMatches(night, at(2026, 11, 5, 2), Q.gameDate(at(2026, 11, 5, 2), 4), 4);
  cases.window_noon = Q.scheduleMatches(night, at(2026, 11, 4, 12), Q.gameDate(at(2026, 11, 4, 12), 4), 4);

  // Nov 4 2026 is a Wednesday (3).
  const weds = { days: [3], months: [], startDate: "", endDate: "", from: "", to: "" };
  cases.days_weds = Q.scheduleMatches(weds, NOV4, Q.gameDate(NOV4, 4), 4);
  cases.days_thu = Q.scheduleMatches(weds, at(2026, 11, 5, 12), Q.gameDate(at(2026, 11, 5, 12), 4), 4);
}

// A condition on another quest's progress.
{
  const b = board();
  const gated = Q.newItem({ id: "gated", name: "Bonus", conditions: [{ item: "wish", when: "today", op: "done" }] });
  b.items.push(gated);
  cases.gated_before = Q.isVisible(b, gated, NOV4);
  Q.tap(b, Q.findItem(b, "wish"), NOV4, 20);
  cases.gated_after = Q.isVisible(b, gated, NOV4);
}

// Weekly resets on Monday.
{
  const weekly = Q.newItem({ id: "w", reset: "weekly" });
  cases.weekly_wed = Q.periodKey(weekly, Q.gameDate(NOV4, 4));
  cases.weekly_sun = Q.periodKey(weekly, Q.gameDate(at(2026, 11, 8, 12), 4));
  cases.weekly_mon = Q.periodKey(weekly, Q.gameDate(at(2026, 11, 9, 12), 4));
}

// Prune drops old days and log entries but keeps the never-reset count.
{
  const b = board();
  Q.tap(b, Q.findItem(b, "shovel"), at(2026, 8, 1));
  Q.tap(b, Q.findItem(b, "wish"), at(2026, 8, 1));
  Q.prune(b, NOV4);
  cases.prune = { periods: Object.keys(b.counts), log: b.log.length };
}

// A count-down shovel starts full; a rock's 8 hits take 8 off, and it stops
// at empty rather than going below.
{
  const b = { settings: { resetHour: 4 }, counts: {}, log: [], items: [] };
  const shovel = Q.newItem({ id: "down", target: { mode: "fixed", value: 100 }, reset: "never", countDown: true });
  const rock = Q.newItem({ id: "stone", effects: [{ on: "tap", kind: "add", item: "down", amount: 8 }] });
  b.items.push(shovel, rock);
  const day = Q.gameDate(NOV4, 4);
  const shown = () => Q.shownCount(shovel, Q.countOf(b, shovel, day), Q.resolveTarget(b, shovel, day));
  cases.down_new = shown();
  Q.tap(b, rock, NOV4);
  cases.down_after_rock = shown();
  Q.tap(b, shovel, NOV4, 200);
  cases.down_empty = { shown: shown(), done: Q.isDone(b, shovel, day) };
}

process.stdout.write(JSON.stringify({ cases }));
