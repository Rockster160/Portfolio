// Drives a rotation quest through a fortnight — what was picked last week,
// what has been picked this week, a fixed day displaced, an extra turning up
// beside the day's pick — and prints JSON for quest_rotation_spec.rb.

import esbuild from "esbuild";
import { fileURLToPath } from "url";

const built = await esbuild.build({
  stdin: {
    contents:   `export { default as R } from "./rotation"; export { default as Q } from "./rules";`,
    resolveDir: fileURLToPath(new URL("../../app/javascript/src/pages/quests/", import.meta.url)),
  },
  bundle:   true,
  format:   "esm",
  write:    false,
  logLevel: "silent",
});

const { R, Q } = await import(
  "data:text/javascript;base64," + Buffer.from(built.outputFiles[0].text).toString("base64")
);

const day = (m, d) => new Date(2026, m - 1, d);
const WED = day(11, 11);
const option = (id, attrs = {}) => R.newOption({ id, name: id, ...attrs });
const item = R.newRotation({
  id:      "visitors",
  name:    "Visitors",
  options: [
    option("a"), option("b"), option("c"), option("d"),
    option("sat", { day: 6 }), option("sun", { day: 0 }),
    option("x", { slot: "extra" }),
  ],
});
const other = R.newRotation({ id: "gone", options: [option("z")] });
const board = { settings: { resetHour: 4 }, items: [item], counts: {}, log: [], rotations: { gone: { "2026-11-10": { main: "z", extras: [] } } } };

R.toggle(board, item, day(11, 3), "c");
R.toggle(board, item, day(11, 4), "a");
R.toggle(board, item, day(11, 9), "b");
R.toggle(board, item, day(11, 10), "a");

const summary = () => Object.fromEntries(R.standings(board, item, WED).map(o => [o.id, { picked: o.picked, due: o.due }]));
const cases = {};

cases.week = R.weekDays(WED).map(d => Q.dayKey(d));
cases.mains = R.weekDays(WED).map(d => R.mainOn(board, item, d));
cases.standings = summary();

R.toggle(board, item, day(11, 14), "d");
cases.fixed_displaced = { main: R.mainOn(board, item, day(11, 14)), standings: summary() };

R.toggle(board, item, day(11, 15), "x");
cases.extra = { main: R.mainOn(board, item, day(11, 15)), extras: R.extrasOn(board, item, day(11, 15)) };
R.toggle(board, item, day(11, 15), "x");
cases.extra_taken_back = R.extrasOn(board, item, day(11, 15));

R.toggle(board, item, day(11, 10), "a");
cases.main_taken_back = R.mainOn(board, item, day(11, 10));

R.toggle(board, item, day(8, 1), "a");
R.prune(board, WED);
cases.pruned = { days: Object.keys(board.rotations.visitors).sort(), rotations: Object.keys(board.rotations) };

// Quests that only show while a visitor is in town: picked as the day's main,
// turned up as an extra, or coming on its fixed day. Noon on each game day.
{
  const wisp = option("wisp");
  const visitors = R.newRotation({
    id: "town", name: "Visitors", options: [wisp, option("sat", { day: 6 }), option("x", { slot: "extra" })],
  });
  const spirits = Q.newItem({
    id: "spirits", name: "Collect {n} spirits", target: { mode: "fixed", value: 5 },
    conditions: [{ item: "town", option: "wisp", when: "today", op: "here" }],
  });
  const quiet = Q.newItem({ id: "quiet", conditions: [{ item: "town", option: "wisp", when: "today", op: "not_here" }] });
  const after = Q.newItem({ id: "after", conditions: [{ item: "town", option: "wisp", when: "yesterday", op: "here" }] });
  const onSat = Q.newItem({ id: "on_sat", conditions: [{ item: "town", option: "sat", when: "today", op: "here" }] });
  const withX = Q.newItem({ id: "with_x", conditions: [{ item: "town", option: "x", when: "today", op: "here" }] });
  const town = { settings: { resetHour: 4 }, items: [visitors, spirits, quiet, after, onSat, withX], counts: {}, log: [] };
  const noon = d => new Date(2026, 10, d, 12);
  const shown = d => town.items.filter(i => !R.isRotation(i) && Q.isVisible(town, i, noon(d))).map(i => i.id);

  const before = shown(12);
  R.toggle(town, visitors, day(11, 12), "wisp");
  R.toggle(town, visitors, day(11, 14), "x");
  cases.visitor = {
    before,
    wisp_day:   shown(12),
    next_day:   shown(13),
    saturday:   shown(14),
  };
  R.toggle(town, visitors, day(11, 12), "wisp");
  cases.visitor.wisp_taken_back = shown(12);

  R.toggle(town, visitors, day(11, 12), "wisp");
  visitors.options = visitors.options.filter(o => o.id !== "wisp");
  Q.dropMissingVisitors(town);
  cases.visitor.removed = {
    spirits: Q.findItem(town, "spirits").conditions,
    on_sat:  Q.findItem(town, "on_sat").conditions.length,
  };
}

process.stdout.write(JSON.stringify({ cases }));
