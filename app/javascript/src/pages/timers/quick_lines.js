// The page builder's line syntax: one line, one timer. Every line means
// something — whatever isn't recognised as an option is the name — so
// there is no way to type it wrong, only ways to type more.
//
//   10s                 10 second countdown
//   Pasta 9 min         countdown named Pasta
//   Rocco               counter from 0
//   Chelsea 50          counter from 50
//   Score /10           counter from 0, capped at 10
//   Turn: Rocco, Eve    dial with one section per name
//
// Options go anywhere on the line:
//   countdowns  repeat · alarm · quiet · bell / ding / beep / chime
//   counters    +5 (step) · 0..10 (range) · /10 · min 0 · max 10
//   any timer   x3 (three of them) · #red / #f80 (color)
//               small · big · full (card size)
//   "Big Mike"  quotes keep words as the name, never an option
//   # note      a # followed by a space starts a comment
//
// The timer form runs it both ways: a line fills the fields, and the
// fields write the line back (serializeLine), so either can be edited.

import { parseDuration, humanizeSeconds, formatDurationShort } from "./duration";
import { ALL_COLORS } from "./colors";

const COLOR_NAMES = {
  blue: "#388bfd", purple: "#a371f7", pink: "#db61a2", orange: "#f0883e",
  yellow: "#e3b341", green: "#3fb950", cyan: "#34d0e0", teal: "#34d0e0",
  red: "#ff7b72", white: "#e6edf3", gray: "#8b949e", grey: "#8b949e",
};

const CHIMES = ["soft", "bell", "ding", "beep", "chime"];

const SIZE_WORDS = { small: 1, medium: 2, big: 3, large: 3, full: 4, wide: 4 };
const SIZE_NAMES = { 1: "small", 2: "medium", 3: "large", 4: "full width" };

const UNIT_SECONDS = {
  s: 1, sec: 1, secs: 1, second: 1, seconds: 1,
  m: 60, min: 60, mins: 60, minute: 60, minutes: 60,
  h: 3600, hr: 3600, hrs: 3600, hour: 3600, hours: 3600,
};

const MAX_COPIES = 50;

function stripComment(line) {
  const m = line.match(/(^|\s)#(\s|$)/);
  return (m ? line.slice(0, m.index) : line).trim();
}

function tokenize(text) {
  const tokens = [];
  text.replace(/"([^"]*)"|(\S+)/g, (_, quoted, bare) => {
    tokens.push(quoted != null ? { text: quoted, literal: true } : { text: bare });
    return "";
  });
  return tokens;
}

// A dial is "Name: a, b, c" — the comma is what separates it from a
// colon time like 4:30 or a name that happens to hold a colon.
function splitDial(line) {
  const m = line.match(/^([^:]*):(.*,.*)$/);
  if (!m) return null;
  const sections = m[2].split(",").map((s) => s.trim()).filter(Boolean);
  return sections.length >= 2 ? { head: m[1], sections } : null;
}

export function parseLine(raw) {
  const line = stripComment(String(raw || ""));
  if (!line) return null;

  const dial = splitDial(line);
  const tokens = tokenize(dial ? dial.head : line);
  const spec = {
    name: [], seconds: 0, value: null, step: null, min: null, max: null,
    repeat: false, alarm: false, quiet: false, chime: null,
    color: null, size: null, copies: 1,
  };

  for (let i = 0; i < tokens.length; i += 1) {
    const { text, literal } = tokens[i];
    if (literal) { spec.name.push(text); continue; }
    const t = text.toLowerCase();
    const word = (n) => (tokens[n] && !tokens[n].literal ? tokens[n].text.toLowerCase() : null);
    const next = word(i + 1);
    // "3 min" is a duration; "3 min 0" is a start of 3 with a floor of 0.
    const boundFollows = next === "min" && /^-?\d+$/.test(word(i + 2) || "");
    let m;

    if (/^\d+(\.\d+)?$/.test(t) && next && UNIT_SECONDS[next] && !boundFollows) {
      spec.seconds += Math.round(parseFloat(t) * UNIT_SECONDS[next]);
      i += 1;
    } else if ((t === "min" || t === "max") && next && /^-?\d+$/.test(next)) {
      spec[t] = parseInt(next, 10);
      i += 1;
    } else if ((m = t.match(/^x(\d+)$/) || t.match(/^(\d+)x$/))) {
      spec.copies = Math.min(MAX_COPIES, Math.max(1, parseInt(m[1], 10)));
    } else if ((m = t.match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/))) {
      spec.color = `#${m[1]}`;
    } else if ((m = t.match(/^#([a-z]+)$/)) && COLOR_NAMES[m[1]]) {
      spec.color = COLOR_NAMES[m[1]];
    } else if ((m = t.match(/^\+(\d+)$/))) {
      spec.step = parseInt(m[1], 10) || null;
    } else if ((m = t.match(/^(-?\d+)\.\.(-?\d+)$/))) {
      spec.min = parseInt(m[1], 10);
      spec.max = parseInt(m[2], 10);
    } else if ((m = t.match(/^\/(\d+)$/))) {
      spec.min = spec.min ?? 0;
      spec.max = parseInt(m[1], 10);
    } else if (/^-?\d+$/.test(t)) {
      spec.value = parseInt(t, 10);
    } else if (!t.startsWith("-") && parseDuration(t)) {
      spec.seconds += parseDuration(t);
    } else if (t === "repeat" || t === "loop") {
      spec.repeat = true;
    } else if (t === "alarm") {
      spec.alarm = true;
    } else if (t === "quiet" || t === "silent") {
      spec.quiet = true;
    } else if (CHIMES.includes(t)) {
      spec.chime = t;
    } else if (SIZE_WORDS[t]) {
      spec.size = SIZE_WORDS[t];
    } else {
      spec.name.push(text);
    }
  }

  const kind = dial ? "dial" : (spec.seconds > 0 ? "countdown" : "counter");
  // Whether the line itself said what kind it is. A bare name doesn't —
  // the builder reads that as a counter; the timer form keeps whatever
  // type is already picked.
  const kindSaid = !!dial || spec.seconds > 0 || spec.value != null
    || spec.step != null || spec.min != null || spec.max != null;
  return { ...spec, kind, kindSaid, name: spec.name.join(" "), sections: dial?.sections || [] };
}

// Lines → the attributes `bulkCreate` takes, copies expanded. Timers
// without a color take the next one round the palette, so a scoreboard
// comes out with every player distinguishable.
export function linesToTimers(text) {
  const timers = [];
  String(text || "").split("\n").forEach((raw) => {
    const spec = parseLine(raw);
    if (!spec) return;
    for (let n = 1; n <= spec.copies; n += 1) {
      const name = spec.copies > 1 && spec.name ? `${spec.name} ${n}` : spec.name;
      timers.push(timerAttrs(spec, name, timers.length));
    }
  });
  return timers;
}

function timerAttrs(spec, name, index) {
  const attrs = { kind: spec.kind, name, color: spec.color || ALL_COLORS[index % ALL_COLORS.length] };
  if (spec.size) attrs.width = spec.size;

  if (spec.kind === "countdown") {
    attrs.duration_ms = spec.seconds * 1000;
    attrs.repeat = spec.repeat;
    const sound = soundFromSpec(spec);
    attrs.callbacks = sound ? [{
      id:   "cb-builder-sound",
      when: { type: "complete" },
      then: { type: "sound", ...sound },
    }] : [];
  } else if (spec.kind === "counter") {
    const start = spec.value ?? spec.min ?? 0;
    attrs.value = start;
    attrs.reset_value = start;
    if (spec.step) attrs.step = spec.step;
    if (spec.min != null) attrs.min_value = spec.min;
    if (spec.max != null) attrs.max_value = spec.max;
  } else {
    attrs.dial_config = { sections: spec.sections.map((s) => ({ name: s, subs: [] })), start_offset: 0 };
    attrs.dial_step_index = 0;
  }
  return attrs;
}

// What a line will make, in words — shown under the box as it's typed,
// so the syntax explains itself.
export function describeLine(spec) {
  const bits = [];
  if (spec.kind === "countdown") {
    bits.push(`${humanizeSeconds(spec.seconds)} countdown`);
    if (spec.repeat) bits.push("repeats");
    if (spec.quiet) bits.push("silent");
    else if (spec.alarm) bits.push("rings until stopped");
    if (spec.chime && !spec.quiet) bits.push(`${spec.chime} sound`);
  } else if (spec.kind === "counter") {
    bits.push(`counter from ${spec.value ?? spec.min ?? 0}`);
    if (spec.step) bits.push(`steps of ${spec.step}`);
    if (spec.min != null && spec.max != null) bits.push(`${spec.min} to ${spec.max}`);
    else if (spec.max != null) bits.push(`up to ${spec.max}`);
    else if (spec.min != null) bits.push(`down to ${spec.min}`);
  } else {
    bits.push(`dial: ${spec.sections.join(" → ")}`);
  }
  if (spec.size) bits.push(SIZE_NAMES[spec.size]);
  if (spec.copies > 1) bits.push(`× ${spec.copies}`);
  return bits.join(" · ");
}

// The name a card will show: a countdown without one goes by its length.
export function displayName(spec) {
  if (spec.name) return spec.name;
  return spec.kind === "countdown" ? formatDurationShort(spec.seconds) : "Untitled";
}

export function previewLines(text) {
  return String(text || "").split("\n").map(parseLine).filter(Boolean);
}

// The finishing sound a line asks for, or null for none.
export function soundFromSpec(spec) {
  if (spec.quiet) return null;
  return { chime: spec.chime || (spec.alarm ? "bell" : "soft"), cadence: spec.alarm ? "10s" : "once" };
}

function soundWords(sound) {
  if (!sound) return ["quiet"];
  const alarm = !!sound.cadence && sound.cadence !== "once";
  const words = alarm ? ["alarm"] : [];
  if (sound.chime && sound.chime !== (alarm ? "bell" : "soft")) words.push(sound.chime);
  return words;
}

const SIZE_TOKENS = { 1: "small", 2: "medium", 3: "big", 4: "full" };

// A name that would read as an option on its own goes in quotes.
function quoteName(name) {
  const p = parseLine(name);
  const plain = p && p.name === name && !p.kindSaid && p.kind !== "dial" && !p.size && !p.color
    && !p.repeat && !p.alarm && !p.quiet && !p.chime && p.copies === 1;
  return plain ? name : `"${name}"`;
}

// Fields back to a line — the inverse of parseLine for everything a line
// can say. `sound` is { chime, cadence } or null; `sections` is a list of
// plain section names, or null when the dial has more than a line holds.
export function serializeLine(f) {
  const head = f.name ? [quoteName(f.name)] : [];
  const opts = [];

  if (f.kind === "countdown") {
    if (f.seconds > 0) opts.push(formatDurationShort(f.seconds));
    if (f.repeat) opts.push("repeat");
    opts.push(...soundWords(f.sound));
  } else if (f.kind === "counter") {
    const value = f.value ?? 0;
    if (value !== (f.min ?? 0)) opts.push(String(value));
    if (f.step && f.step !== 1) opts.push(`+${f.step}`);
    if (f.min === 0 && f.max != null) opts.push(`/${f.max}`);
    else if (f.min != null && f.max != null) opts.push(`${f.min}..${f.max}`);
    else if (f.min != null) opts.push(`min ${f.min}`);
    else if (f.max != null) opts.push(`max ${f.max}`);
  }

  if (f.size) opts.push(SIZE_TOKENS[f.size]);
  if (f.color) {
    const named = Object.keys(COLOR_NAMES).find((k) => COLOR_NAMES[k] === f.color.toLowerCase());
    opts.push(named ? `#${named}` : f.color.toLowerCase());
  }
  if (f.copies > 1) opts.push(`x${f.copies}`);

  const line = [...head, ...opts].join(" ");
  if (f.kind === "dial" && f.sections?.length >= 2) return `${line}: ${f.sections.join(", ")}`;
  return line;
}
