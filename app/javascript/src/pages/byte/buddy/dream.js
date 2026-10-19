// The pet's thought bubble on a board: what it WANTS, or an idea, as opposed to
// the speech bubble's standing alerts. Two sources, strongest first:
//
//   1. a dream sent from Jil (`Buddy.dream` — Whisper wanting food), aimed at a
//      group the board watches. The newest one sent is the one shown.
//   2. otherwise, now and then, one of the board's hot chores. Time runs in
//      cycles set per board: a dream lasts `dreamMinutes`, then the pet rests
//      for `breakMinutes`, and round again. Each cycle is a fresh draw,
//      weighted the way the morning hot picks are (each item carries its
//      `hot_weight`), with a slot for dreaming of nothing so the bubble isn't
//      always up. The same chore can win several rounds running.
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

export const DEFAULT_PACE = { dreamMinutes: 30, breakMinutes: 0 };
// The weight of dreaming of nothing - one ordinary chore's worth.
export const REST_WEIGHT = 1.0;
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

// Where `nowMs` sits in the board's dream/break cycle.
function cycleAt(nowMs, pace) {
  const dreamMs = pace.dreamMinutes * 60000;
  const cycleMs = dreamMs + pace.breakMinutes * 60000;
  const offset = nowMs % cycleMs;
  return { cycle: Math.floor(nowMs / cycleMs), offset, dreamMs, cycleMs, resting: offset >= dreamMs };
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

// The hot chore this board dreams of right now, or null for nothing (a break,
// or the draw landing on rest).
export function pickChoreDream(items, boardId, nowMs, pace = DEFAULT_PACE) {
  const pool = dreamCandidates(items);
  if (!pool.length) return null;

  const at = cycleAt(nowMs, pace);
  if (at.resting) return null;

  const total = pool.reduce((sum, item) => sum + Number(item.hot_weight), 0) + REST_WEIGHT;
  let roll = mulberry32(dreamSeed(boardId, at.cycle)) * total;
  for (const item of pool) {
    roll -= Number(item.hot_weight);
    if (roll < 0) return item;
  }
  return null;
}

// The newest Jil dream aimed at a group this board watches.
export function newestDream(alerts, tags) {
  return (alerts || [])
    .filter((a) => a && a.dream && a.body && groupsOverlap(a.groups, tags))
    .sort((a, b) => String(b.last_raised_at || "").localeCompare(String(a.last_raised_at || "")))[0] || null;
}

export function initBoardDream({
  bubble, hero, tags, boardIdFn, iconFor, choreDreams = true, pace = DEFAULT_PACE,
}) {
  if (!bubble) {
    return {
      setAlerts: () => {}, setItems: () => {}, setTags: () => {}, setChoreDreams: () => {}, setPace: () => {},
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
    const dream = newestDream(alerts, watched);
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
    const chore = choreDreams ? pickChoreDream(items, boardIdFn?.(), Date.now(), pace) : null;
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

  // A fresh look at each turn of the cycle (a dream starting or a break
  // starting), all screens together.
  function scheduleSlot() {
    clearTimeout(slotTimer);
    const at = cycleAt(Date.now(), pace);
    const wait = (at.resting ? at.cycleMs - at.offset : at.dreamMs - at.offset) + 1000;
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
      pace = {
        dreamMinutes: Number(next?.dreamMinutes) || DEFAULT_PACE.dreamMinutes,
        breakMinutes: Number(next?.breakMinutes) || 0,
      };
      scheduleSlot();
      render();
    },
  };
}
