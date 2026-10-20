// The pet's thought bubble on a board: what it WANTS, or an idea, as opposed to
// the speech bubble's standing alerts. Two sources, strongest first:
//
//   1. a dream sent from Jil (`Buddy.dream` — Whisper wanting food), aimed at a
//      group the board watches. The newest one sent is the one shown.
//   2. otherwise, now and then, one of the board's hot chores, at the board's
//      own pace: a fresh draw `every` minutes, weighted the way the morning hot
//      picks are (each item carries its `hot_weight`), landing on nothing
//      `blank` percent of the time. After a chore shows, the pet rests for
//      `rest` minutes, and nothing shows in its quiet hours. The same chore can
//      win several rounds running.
//
// The pet wears a dream's face (thinking, unless the dream names one) as a SOFT
// hold on the hero: it shows only while nothing else is held and the pet's mood
// is idle, so any real face takes over and the dream face returns after.
//
// The draw is seeded by the cycle and the board, so every screen showing a
// board agrees, and the server opens the page already wearing the face this is
// about to pick. Buddy::BoardDream makes the same draw in Ruby; the two must
// stay identical (spec/javascript/board_dream_spec.rb).

import { FACE_STRENGTH, strengthOr } from "./face_strength.js";
import { groupsOverlap } from "./board_scope.js";

export const DEFAULT_PACE = { every: 30, blank: 25, rest: 0, quietFrom: null, quietTo: null };
const DREAM_FACE = "thinking";
const DREAM_HOLD = "board-dream";

// mulberry32: a float in [0, 1) from a 32-bit seed.
export function mulberry32(seed) {
  let a = seed | 0;
  a = (a + 0x6d2b79f5) | 0;
  let t = Math.imul(a ^ (a >>> 15), 1 | a);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
  return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
}

export function dreamSeed(boardId, cycle) {
  return (cycle * 31 + Number(boardId || 0)) >>> 0;
}

// A board's pace from its metadata (or a broadcast of it), defaults filled in.
// The server only ever stores values it offers.
export function paceFromMeta(meta) {
  const m = meta || {};
  const hour = (v) => (v === null || v === undefined || v === "" ? null : Number(v));
  return {
    every: Number(m.dream_minutes) || DEFAULT_PACE.every,
    blank: m.dream_blank_percent == null ? DEFAULT_PACE.blank : Number(m.dream_blank_percent),
    rest: Number(m.dream_rest_minutes) || 0,
    quietFrom: hour(m.dream_quiet_from),
    quietTo: hour(m.dream_quiet_to),
  };
}

// "Every 30 min, rest 1 hr, quiet 9 PM–7 AM": how a board's dreams are set,
// for the row that opens their dialog.
export function dreamSummary(on, pace) {
  if (!on) return "Off";

  const mins = (m) => (m < 60 ? `${m} min` : `${m / 60} hr`);
  const hour = (h) => `${((h + 11) % 12) + 1} ${h < 12 ? "AM" : "PM"}`;
  const parts = [`Every ${mins(pace.every)}`];
  if (pace.rest) parts.push(`rest ${mins(pace.rest)}`);
  if (pace.quietFrom !== null && pace.quietTo !== null && pace.quietFrom !== pace.quietTo) {
    parts.push(`quiet ${hour(pace.quietFrom)}–${hour(pace.quietTo)}`);
  }
  return parts.join(", ");
}

// Rests are worked out from the board's local midnight: the first cycle
// starting at or after it, so every screen agrees on where they fall.
function dayFirstCycle(ms, cycleMs, utcOffset) {
  const localMinutes = Math.floor(ms / 60000) + utcOffset;
  const dayStartMs = (Math.floor(localMinutes / 1440) * 1440 - utcOffset) * 60000;
  return Math.ceil(dayStartMs / cycleMs);
}

function quietAt(ms, pace, utcOffset) {
  const { quietFrom: from, quietTo: to } = pace;
  if (from === null || to === null || from === to) return false;

  const hour = (((Math.floor((Math.floor(ms / 60000) + utcOffset) / 60)) % 24) + 24) % 24;
  return from < to ? hour >= from && hour < to : hour >= from || hour < to;
}

// One cycle's draw: nothing `blank` percent of the time, else a hot chore.
function drawCycle(pool, boardId, cycle, blank) {
  const r = mulberry32(dreamSeed(boardId, cycle));
  const cut = blank / 100;
  if (r < cut) return null;

  let roll = ((r - cut) / (1 - cut)) * pool.reduce((sum, item) => sum + Number(item.hot_weight), 0);
  for (const item of pool) {
    roll -= Number(item.hot_weight);
    if (roll < 0) return item;
  }
  return pool[pool.length - 1];
}

// Hot chores still asking today, in id order so both sides walk them alike.
export function dreamCandidates(items) {
  return (items || [])
    .filter(
      (item) =>
        (item.kind || "chore") === "chore" &&
        Number(item.hot_weight) > 0 &&
        item.today_visible &&
        !item.archived &&
        Number(item.progress_count) < Number(item.target_count) &&
        !item.skipped_today &&
        !item.dismissed,
    )
    .sort((a, b) => Number(a.id) - Number(b.id));
}

// The hot chore this board dreams of right now, or null for nothing (quiet
// hours, a rest, the draw landing on nothing, or the pet tapped since this draw
// at `dismissedAt` ms). `utcOffset` is the board's local offset in minutes,
// which places its quiet hours.
export function pickChoreDream(
  items, boardId, nowMs, pace = DEFAULT_PACE, utcOffset = localOffset(nowMs), dismissedAt = 0,
) {
  pace = { ...DEFAULT_PACE, ...pace };
  const pool = dreamCandidates(items);
  if (!pool.length) return null;
  if (quietAt(nowMs, pace, utcOffset)) return null;

  const cycleMs = pace.every * 60000;
  const cycle = Math.floor(nowMs / cycleMs);
  const restCycles = Math.ceil(pace.rest / pace.every);
  const first = dayFirstCycle(cycle * cycleMs, cycleMs, utcOffset);
  const shown = new Map();
  for (let k = first; k <= cycle; k++) {
    let resting = false;
    for (let j = Math.max(k - restCycles, first); j < k; j++) if (shown.get(j)) resting = true;
    const quiet = quietAt(k * cycleMs, pace, utcOffset);
    shown.set(k, !resting && !quiet ? drawCycle(pool, boardId, k, pace.blank) : null);
  }
  if (dismissedAt && dismissedAt >= cycle * cycleMs) return null;

  return shown.get(cycle) || null;
}

// The device's offset from UTC in minutes, east positive (Ruby's sign).
function localOffset(ms) {
  return -new Date(ms).getTimezoneOffset();
}

// The newest Jil dream aimed at a group this board watches, raised since the
// pet was last tapped.
export function newestDream(alerts, tags, dismissedAt = 0) {
  return (alerts || [])
    .filter((a) => a && a.dream && a.body && groupsOverlap(a.groups, tags))
    .filter((a) => !dismissedAt || Date.parse(a.last_raised_at || "") > dismissedAt)
    .sort((a, b) => String(b.last_raised_at || "").localeCompare(String(a.last_raised_at || "")))[0] || null;
}

export function initBoardDream({
  bubble, hero, tags, boardIdFn, iconFor, choreDreams = true, pace = DEFAULT_PACE, dismissedAt = 0,
}) {
  if (!bubble) {
    return {
      setAlerts: () => {}, setItems: () => {}, setTags: () => {}, setChoreDreams: () => {}, setPace: () => {},
      dismiss: () => {},
    };
  }

  let watched = Array.isArray(tags) ? tags : [];
  let alerts = [];
  let items = [];
  let shown = null;
  let slotTimer = 0;

  function clear() {
    if (shown === null) return;
    shown = null;
    bubble.hidden = true;
    bubble.textContent = "";
    hero?.releaseExpression?.(DREAM_HOLD);
  }

  // Redrawn only when what it says changed: a resync every household tap must
  // not rebuild the bubble under the person reading it.
  function show(key, build, face, strength = FACE_STRENGTH.dream) {
    if (shown === key) return;
    shown = key;
    bubble.textContent = "";
    build();
    bubble.hidden = false;
    hero?.holdExpression?.(DREAM_HOLD, face || DREAM_FACE, strength);
  }

  function line(text) {
    const span = document.createElement("span");
    span.className = "byte-board-dream-text";
    span.textContent = text;
    return span;
  }

  function render() {
    const dream = newestDream(alerts, watched, dismissedAt);
    if (dream) {
      return show(`dream:${dream.id}:${dream.body}:${dream.icon || ""}:${dream.expression || ""}:${dream.strength || ""}`, () => {
        if (dream.icon) {
          const icon = document.createElement("span");
          icon.className = "byte-board-dream-icon";
          icon.textContent = dream.icon;
          bubble.appendChild(icon);
        }
        bubble.appendChild(line(dream.body));
      }, dream.expression, strengthOr(dream.strength, FACE_STRENGTH.dream));
    }

    // Hot-chore dreams can be switched off per board; Jil's still show.
    const chore = choreDreams ? pickChoreDream(items, boardIdFn?.(), Date.now(), pace, undefined, dismissedAt) : null;
    if (!chore) return clear();

    show(`chore:${chore.id}:${chore.short_name}`, () => {
      const icon = iconFor?.(chore);
      if (icon) {
        icon.classList.add("byte-board-dream-icon");
        bubble.appendChild(icon);
      }
      bubble.appendChild(line(chore.short_name || chore.name || ""));
    });
  }

  // A fresh look at each new draw, all screens together.
  function scheduleSlot() {
    clearTimeout(slotTimer);
    // The next draw, or the next hour if sooner - where quiet hours turn.
    const now = Date.now();
    const cycleMs = pace.every * 60000;
    const wait = Math.min(cycleMs - (now % cycleMs), 3600000 - (now % 3600000)) + 1000;
    slotTimer = window.setTimeout(() => {
      render();
      scheduleSlot();
    }, wait);
  }
  scheduleSlot();

  return {
    setAlerts(next) {
      if (Array.isArray(next)) alerts = next;
      render();
    },
    setItems(next) {
      if (Array.isArray(next)) items = next;
      render();
    },
    setTags(next) {
      watched = Array.isArray(next) ? next.map((t) => String(t).toLowerCase()) : [];
      render();
    },
    setChoreDreams(on) {
      choreDreams = on !== false;
      render();
    },
    setPace(next) {
      pace = { ...DEFAULT_PACE, ...next };
      scheduleSlot();
      render();
    },
    // The pet was tapped: put away whatever shows until the next draw or a
    // dream raised after `at` (ms, or an ISO time from the server).
    dismiss(at) {
      const ms = typeof at === "number" ? at : Date.parse(at || "");
      if (!Number.isFinite(ms) || ms <= dismissedAt) return;
      dismissedAt = ms;
      render();
    },
  };
}
