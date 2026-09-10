// Feeds the typed-duration fixtures through the real parser and prints the
// results as JSON for duration_parse_spec.rb. Pure string -> number|null, no DOM.
//
// The same table is what the Jil `Parse Duration` function has to agree with —
// that function is the one deciding what gets STORED, this one only says live
// what it is about to do. A drift between them shows up as a box that promises
// 92 minutes and records something else.
import {
  parseDurationMinutes,
  formatDurationHint,
} from "../../app/javascript/src/support/parse_duration.js";

const cases = {
  blank: "",
  whitespace: "   ",
  bare_minutes: "52",
  clock_h_mm: "1:32",
  clock_h_mm_ss: "1:04:35",
  minutes_suffix: "97m",
  hours_then_bare: "1h 32",
  compact_h_and_m: "11h24m",
  hours_only: "1h",
  spelled_minutes: "90 minutes",
  spelled_hour_then_bare: "1 hour 32",
  no_space_h_then_bare: "2h30",
  fractional_hours: "1.5h",
  seconds_only: "30s",
  unreadable: "abc",
  zero: "0",
  already_a_number: "42",
  legacy_mm_ss_reads_as_h_mm: "56:47",
  padded: "  1h 32  ",
  uppercase: "1H 32M",
};

const out = {};
for (const [key, input] of Object.entries(cases)) {
  const minutes = parseDurationMinutes(input);
  out[key] = { input, minutes, hint: formatDurationHint(minutes) };
}
console.log(JSON.stringify(out));
