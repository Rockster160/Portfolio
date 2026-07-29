// Buddy's timer-expiry alarm. Deliberately separate from the Timers app's
// audio.js: it has its OWN mute key (buddy:muted, per the user's choice) and
// couples sound to Buddy's face, which timers/audio.js knows nothing about.
//
// The cry is Hollow-Knight-Grub-ish: three quick descending pulses, repeated
// once a second until the person interacts. While it rings, Buddy's face flips
// between an excited/yelling look and neutral every 0.5s. A single tap anywhere
// acknowledges (the caller wires the actual confirm + stop).

const MUTE_KEY = "buddy:muted";

export function isBuddyMuted() {
  return localStorage.getItem(MUTE_KEY) === "true";
}

// Returns the new muted state. Muting stops any active alarm immediately.
export function setBuddyMuted(value) {
  localStorage.setItem(MUTE_KEY, value ? "true" : "false");
  if (value) stopAlarmSound();
  return value;
}

export function toggleBuddyMuted() {
  return setBuddyMuted(!isBuddyMuted());
}

// --- Web Audio (lazy, born inside a gesture for iOS) -----------------------

let ctx = null;
function getCtx() {
  if (ctx) return ctx;
  const AudioContext = window.AudioContext || window.webkitAudioContext;
  if (!AudioContext) return null;
  ctx = new AudioContext();
  return ctx;
}

// Three descending pulses — the grub "wail". Frequencies fall, each pulse
// short and slightly overlapping so it reads as one cry, not three beeps.
const GRUB_PULSES = [
  { f: 640, t: 0.0, d: 0.15, g: 0.22, w: "triangle" },
  { f: 500, t: 0.16, d: 0.15, g: 0.2, w: "triangle" },
  { f: 380, t: 0.32, d: 0.22, g: 0.2, w: "triangle" },
];

function playGrubOnce() {
  const c = ctx;
  if (!c || c.state !== "running") return;
  const base = c.currentTime + 0.01;
  GRUB_PULSES.forEach(({ f, t, d, g, w }) => {
    const osc = c.createOscillator();
    const gain = c.createGain();
    osc.type = w;
    osc.frequency.setValueAtTime(f, base + t);
    // A slight downward glide within each pulse deepens the "wail".
    osc.frequency.exponentialRampToValueAtTime(f * 0.85, base + t + d);
    gain.gain.setValueAtTime(0, base + t);
    gain.gain.linearRampToValueAtTime(g, base + t + 0.02);
    gain.gain.exponentialRampToValueAtTime(0.0001, base + t + d);
    osc.connect(gain);
    gain.connect(c.destination);
    osc.start(base + t);
    osc.stop(base + t + d + 0.05);
  });
}

// --- Alarm lifecycle -------------------------------------------------------

// Flip between EXCITED and neutral while ringing — [excited, default]. Per
// theme, because Byte and Moss have different face sets: a name valid for one
// renders blank on the other (that blank frame was the "flashing in and out").
// Every name here is verified to exist as a face_<name>.png + a SCSS rule for
// its theme (byte: uwu/neutral, moss: star/neutral).
const ALARM_FACES = {
  byte: ["uwu", "neutral"],
  moss: ["star", "neutral"],
};
function alarmFaces() {
  const theme = document.querySelector("[data-buddy-hero]")?.dataset.buddyTheme;
  return ALARM_FACES[theme] || ALARM_FACES.byte;
}

let soundInterval = 0;
let faceInterval = 0;
let running = false;

// Start ringing + the face loop. Idempotent — a second expiring timer while one
// already rings just keeps the single alarm going. `hero` is the buddy hero
// handle (setExpression). Sound is skipped when muted, but the face loop still
// runs so there's a visual even on silent.
export function startAlarm({ hero }) {
  if (running) return;
  running = true;

  const c = getCtx();
  if (c && c.state === "suspended") c.resume().catch(() => {});

  if (!isBuddyMuted()) {
    playGrubOnce();
    soundInterval = window.setInterval(playGrubOnce, 1000);
  }

  const [faceA, faceB] = alarmFaces();
  let flip = false;
  // Paint the first frame immediately so the toggle is visible from tick one.
  hero?.setExpression(faceA, { transient: true });
  faceInterval = window.setInterval(() => {
    flip = !flip;
    hero?.setExpression(flip ? faceB : faceA, { transient: true });
  }, 500);
}

// Stop just the sound (used by mute) without touching the face loop.
function stopAlarmSound() {
  if (soundInterval) {
    clearInterval(soundInterval);
    soundInterval = 0;
  }
}

// Fully stop: silence + end the face loop and drop the transient face back to
// the resting mood (clearThinking falls through to the stored expression).
export function stopAlarm({ hero } = {}) {
  running = false;
  stopAlarmSound();
  if (faceInterval) {
    clearInterval(faceInterval);
    faceInterval = 0;
  }
  hero?.restExpression?.();
}

export function alarmRunning() {
  return running;
}
