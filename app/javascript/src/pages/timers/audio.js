// Client-side sound. Sound is purely a frontend concern (server-side
// dispatch is a no-op) so playback is instantaneous, fully cancellable,
// and scoped per timer.
//
// Two compounding bugs the prior version had:
//
//   (1) Stacked tones on first interaction. Browser autoplay policy
//       freezes AudioContext.currentTime while the context is suspended.
//       Scheduling oscillators at `currentTime + 0.01` against a frozen
//       clock queues them all at the same instant; when the user finally
//       interacts, every queued tone plays at once. Fix: do NOT schedule
//       ANY tones while suspended — instead record the intent in
//       `pending` and let a one-shot `click`/`keydown` listener drain
//       it after the context resumes.
//
//   (2) Mute didn't actually mute. The cadence interval kept scheduling
//       tones because `isMuted()` was only checked at the renderer
//       layer. Fix: gate `playSoundNow` and every cadence tick on the
//       mute state, AND have the header's mute click call `stopAllSounds`
//       so the existing chime cuts off the instant the user toggles.
//
// Listener choice: `click` (bubble phase) is used so the card's own
// click handler — which calls `stopTimerSound(id)` — runs FIRST. If the
// user is confirming a timer with a deferred sound, that path removes
// the timer from `pending` before this listener can play it.
//
// Mute is read directly from localStorage here to avoid a header.js ↔
// audio.js circular import (header.js wires the mute button and imports
// `setMuted` from this file). Both read the same `timers:muted` key.

const MUTE_KEY = "timers:muted";
function isMuted() {
  return localStorage.getItem(MUTE_KEY) === "true";
}

let ctx = null;
const live = new Map();    // timerId → { interval, oscillators, gains }
const pending = new Map(); // timerId → { chime, cadence }

function getCtx() {
  if (ctx) return ctx;
  const AudioContext = window.AudioContext || window.webkitAudioContext;
  if (!AudioContext) return null;
  ctx = new AudioContext();
  return ctx;
}

const CHIMES = {
  soft:  [{ f: 880,  t: 0.01, d: 0.45, g: 0.18, w: "sine" },   { f: 660, t: 0.20, d: 0.6, g: 0.16, w: "sine" }],
  bell:  [{ f: 988,  t: 0.01, d: 1.4,  g: 0.22, w: "sine" },   { f: 1318,t: 0.01, d: 1.4, g: 0.10, w: "sine" }],
  ding:  [{ f: 800,  t: 0.01, d: 0.22, g: 0.20, w: "sine" },   { f: 1000,t: 0.18, d: 0.30, g: 0.20, w: "sine" }],
  beep:  [{ f: 660,  t: 0.01, d: 0.20, g: 0.22, w: "square" }],
  chime: [{ f: 523,  t: 0.00, d: 0.5,  g: 0.16, w: "sine" },   { f: 659, t: 0.18, d: 0.5, g: 0.16, w: "sine" }, { f: 784, t: 0.36, d: 0.7, g: 0.16, w: "sine" }],
};

export const CHIME_NAMES = Object.keys(CHIMES);
export const CADENCE_OPTIONS = [
  { value: "once", label: "Once" },
  { value: "1s",   label: "Every second" },
  { value: "10s",  label: "Every 10 seconds" },
  { value: "60s",  label: "Every minute" },
];
const CADENCE_MS = { "1s": 1000, "10s": 10000, "60s": 60000 };

function spawnTone(c, slot, baseTime, tone) {
  const { f, t, d, g, w } = tone;
  const osc = c.createOscillator();
  const gain = c.createGain();
  osc.type = w || "sine";
  osc.frequency.value = f;
  const t0 = baseTime + t;
  gain.gain.setValueAtTime(0, t0);
  gain.gain.linearRampToValueAtTime(g, t0 + 0.015);
  gain.gain.exponentialRampToValueAtTime(0.0001, t0 + d);
  osc.connect(gain);
  gain.connect(c.destination);
  osc.start(t0);
  osc.stop(t0 + d + 0.05);
  slot.oscillators.add(osc);
  slot.gains.add(gain);
  osc.onended = () => {
    slot.oscillators.delete(osc);
    slot.gains.delete(gain);
    try { gain.disconnect(); } catch (e) { /* ignore */ }
  };
}

function playSoundNow(timerId, { chime, cadence }) {
  const c = ctx;
  if (!c || c.state !== "running") return;
  if (isMuted()) return; // muted → never play, even if intent existed

  cleanupLive(timerId);
  const slot = { interval: null, oscillators: new Set(), gains: new Set() };
  live.set(timerId, slot);

  const playOnce = () => {
    // Mute / suspension can change between ticks; recheck every time.
    if (!c || c.state !== "running") return;
    if (isMuted()) return;
    const tones = CHIMES[chime] || CHIMES.soft;
    const baseTime = c.currentTime + 0.01;
    tones.forEach((tone) => spawnTone(c, slot, baseTime, tone));
  };
  playOnce();

  const ms = CADENCE_MS[cadence];
  if (ms) slot.interval = setInterval(playOnce, ms);
}

function cleanupLive(timerId) {
  const slot = live.get(timerId);
  if (!slot) return;
  if (slot.interval) clearInterval(slot.interval);
  // Cancel scheduled gain ramps, force gain to 0, disconnect nodes,
  // stop oscillators. This is what makes confirm() actually silence
  // a timer — otherwise queued tones would still play out their tail.
  slot.gains.forEach((g) => {
    try {
      g.gain.cancelScheduledValues(0);
      g.gain.setValueAtTime(0, 0);
      g.disconnect();
    } catch (e) { /* ignore */ }
  });
  slot.oscillators.forEach((osc) => {
    try { osc.stop(0); } catch (e) { /* ignore */ }
    try { osc.disconnect(); } catch (e) { /* ignore */ }
  });
  slot.oscillators.clear();
  slot.gains.clear();
  live.delete(timerId);
}

let listenerArmed = false;
let listenerHandler = null;

function armInteractionListener() {
  if (listenerArmed) return;
  listenerArmed = true;
  listenerHandler = async (e) => {
    // Tear down listener immediately — one shot.
    document.removeEventListener("click", listenerHandler);
    document.removeEventListener("keydown", listenerHandler);
    listenerArmed = false;
    listenerHandler = null;

    const c = getCtx();
    if (!c) return;
    if (c.state === "suspended") {
      try { await c.resume(); } catch (e) { return; }
    }
    if (c.state !== "running") return;
    if (isMuted()) { pending.clear(); return; }

    // Drain pending. Note: card click handlers run BEFORE this (bubble
    // phase listener attached to document), so any card the user just
    // tapped to confirm has ALREADY removed its timer from `pending`.
    const items = Array.from(pending.entries());
    pending.clear();
    items.forEach(([timerId, sound]) => {
      if (!live.has(timerId)) playSoundNow(timerId, sound);
    });
  };
  // Bubble-phase: card / button click handlers run before this.
  document.addEventListener("click", listenerHandler);
  document.addEventListener("keydown", listenerHandler);
}

export function startTimerSound(timerId, { chime = "soft", cadence = "once" } = {}) {
  // Always reset existing state for this timer first.
  pending.delete(timerId);
  cleanupLive(timerId);

  // Hard mute short-circuit: don't even record an intent.
  if (isMuted()) return;

  const c = getCtx();
  if (!c) return;

  if (c.state === "running") {
    playSoundNow(timerId, { chime, cadence });
    return;
  }

  pending.set(timerId, { chime, cadence });
  c.resume().catch(() => null);
  armInteractionListener();
}

export function stopTimerSound(timerId) {
  pending.delete(timerId);
  cleanupLive(timerId);
}

export function stopAllSounds() {
  pending.clear();
  Array.from(live.keys()).forEach(cleanupLive);
}

// Called by header.js when the user toggles the mute button. When the
// user MUTES, kill everything currently playing AND any deferred intent.
// When they UNMUTE, do nothing — future fires/cadences will play normally.
export function setMuted(value) {
  if (value) stopAllSounds();
}

// Preview is triggered inside a click handler in the modal so the
// context is allowed to resume immediately. Still gated on mute.
export async function previewChime(chime) {
  if (isMuted()) return;
  const c = getCtx();
  if (!c) return;
  if (c.state === "suspended") {
    try { await c.resume(); } catch (e) { return; }
  }
  if (c.state !== "running") return;
  const slot = { oscillators: new Set(), gains: new Set(), interval: null };
  const tones = CHIMES[chime] || CHIMES.soft;
  const baseTime = c.currentTime + 0.01;
  tones.forEach((tone) => spawnTone(c, slot, baseTime, tone));
}
