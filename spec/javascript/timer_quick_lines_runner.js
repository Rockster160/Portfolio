// Feeds page-builder lines through the real parser and prints, per case,
// the timers it would create and the preview text, for
// timer_quick_lines_spec.rb. Pure string -> attrs, no DOM.
//
// The module imports its neighbours without extensions, the way esbuild
// resolves them for the real build, so it's bundled here the same way.
const { build } = await import("esbuild");
const bundled = await build({
  entryPoints: [new URL("../../app/javascript/src/pages/timers/quick_lines.js", import.meta.url).pathname],
  bundle:      true,
  format:      "esm",
  write:       false,
  logLevel:    "silent",
});
const { linesToTimers, parseLine, describeLine, serializeLine } = await import(
  `data:text/javascript;base64,${Buffer.from(bundled.outputFiles[0].text).toString("base64")}`
);

const cases = {
  bare_duration: "10s # This adds a 10s countdown",
  bare_name: "Rocco # This adds a counter named Rocco",
  name_and_start: "Chelsea 50",
  spelled_duration: "Pasta 9 min",
  split_duration: "Bread 1h 30m",
  colon_duration: "Tea 4:30",
  repeat_alarm: "Plank 45s repeat alarm",
  quiet: "Nap 20m quiet",
  chime: "Eggs 6m bell",
  step_and_range: "Score +5 0..100",
  out_of: "Darts /10",
  min_max_words: "Lives 3 min 0 max 5",
  min_as_name: "Min",
  negative_start: "Debt -5",
  copies_named: "Egg 3m x3",
  copies_unnamed: "10s x2",
  hex_color: "Rocco #f80",
  named_color: "Eve #green",
  unknown_hash_word: "Player #1",
  size: "Rocco big",
  quoted_keyword: "\"Big Mike\" 10",
  dial: "Turn: Rocco, Chelsea, Eve",
  colon_name_without_comma: "Note: hello",
  comment_only: "# just a note",
  blank: "   ",
};

const out = {};
for (const [key, input] of Object.entries(cases)) {
  const spec = parseLine(input);
  out[key] = { timers: linesToTimers(input), preview: spec ? describeLine(spec) : null };
}
out.multi = { timers: linesToTimers("10s\nRocco\n\nChelsea 50\n# skip\n") };

// The timer form writes its fields back as a line; each of these should
// read back as the same fields.
const forms = {
  countdown:         { kind: "countdown", name: "Tea", seconds: 180, repeat: false, sound: { chime: "soft", cadence: "once" } },
  countdown_options: { kind: "countdown", name: "Plank", seconds: 45, repeat: true, sound: { chime: "ding", cadence: "10s" } },
  quiet:             { kind: "countdown", name: "", seconds: 600, repeat: false, sound: null },
  counter_plain:     { kind: "counter", name: "Rocco", value: 0, step: 1, min: null, max: null },
  counter_full:      { kind: "counter", name: "Score", value: 0, step: 5, min: 0, max: 100, size: 3, color: "#3fb950" },
  counter_floor:     { kind: "counter", name: "Lives", value: 3, step: 1, min: 0, max: null },
  counter_ceiling:   { kind: "counter", name: "Chelsea", value: 50, step: 1, min: null, max: 60 },
  option_word_name:  { kind: "counter", name: "Big", value: 0, step: 1, min: null, max: null },
  dial:              { kind: "dial", name: "Turn", sections: ["Rocco", "Eve"], size: 4 },
  dial_complex:      { kind: "dial", name: "Game", sections: null },
};
out.serialized = {};
for (const [key, fields] of Object.entries(forms)) {
  const line = serializeLine(fields);
  out.serialized[key] = { line, back: parseLine(line) };
}
console.log(JSON.stringify(out));
