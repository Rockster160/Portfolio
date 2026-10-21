// Board sounds, played on demand from Jil. A task broadcasting
//   Monitor.broadcast("byte", { ...sound: "wake", groups: [...] })
// or a status ring that runs out (its `sound`, see buddy/rings.js) lands here
// as a key, and we play the matching tune. These are the Whisper PWA's
// named beeps, ported so the board that replaces it makes the same sounds —
// nap, wake, birthday, alarm, and a default chirp for anything else.
//
// Honours the pet's own mute (buddy:muted) so the wall tablet's "shush" quiets
// a Jil sound the same way it quiets the timer alarm; the two share the key.

import { beeps } from "../../dashboard/vars";
import { isBuddyMuted } from "./alarm";

const volume = 0.9;

function playDefaultBeeps() {
  beeps([
    [250, 262, volume - 0.2, "sine"],
    [300, 330, volume - 0.1, "sine"],
    [300, 392, volume - 0.15, "sine"],
    [300, 330, volume - 0.1, "sine"],
    [350, 262, volume - 0.2, "sine"],
  ]);
}

function playNapBeeps() {
  beeps([
    [400, 392, volume, "sine"],
    [400, 349, volume, "sine"],
    [400, 330, volume - 0.01, "sine"],
    [400, 294, volume - 0.02, "sine"],
    [600, 262, volume - 0.03, "sine"],
  ]);
}

function playWakeBeeps() {
  beeps([
    [400, 262, volume - 0.03, "sine"],
    [400, 294, volume - 0.02, "sine"],
    [400, 330, volume - 0.01, "sine"],
    [400, 349, volume, "sine"],
    [600, 392, volume, "sine"],
  ]);
}

function playAlarmBeeps() {
  const pulse = [
    [300, 440, volume - 0.3, "sine"],
    [250, 392, volume - 0.4, "sine"],
    [300, 440, volume - 0.3, "sine"],
  ];
  beeps([...pulse, [400, 0, 0, null], ...pulse]);
}

function playHappyBirthdayBeeps() {
  // G4=392, A4=440, B4=494, C5=523, D5=587, E5=659, F5=698, G5=784.
  const G4 = 392,
    A4 = 440,
    B4 = 494,
    C5 = 523,
    D5 = 587,
    E5 = 659,
    F5 = 698,
    G5 = 784;
  const dur = 300;
  const shortDur = 200;

  beeps([
    // Happy birthday to you
    [shortDur, G4, volume, "sine"],
    [shortDur, G4, volume, "sine"],
    [dur, A4, volume, "sine"],
    [dur, G4, volume, "sine"],
    [dur, C5, volume, "sine"],
    [dur * 2, B4, volume, "sine"],
    [200, 0, 0, null],
    // Happy birthday to you
    [shortDur, G4, volume, "sine"],
    [shortDur, G4, volume, "sine"],
    [dur, A4, volume, "sine"],
    [dur, G4, volume, "sine"],
    [dur, D5, volume, "sine"],
    [dur * 2, C5, volume, "sine"],
    [200, 0, 0, null],
    // Happy birthday dear Whisper
    [shortDur, G4, volume, "sine"],
    [shortDur, G4, volume, "sine"],
    [dur, G5, volume, "sine"],
    [dur, E5, volume, "sine"],
    [dur, C5, volume, "sine"],
    [dur, B4, volume, "sine"],
    [dur * 2, A4, volume, "sine"],
    [200, 0, 0, null],
    // Happy birthday to you
    [shortDur, F5, volume, "sine"],
    [shortDur, F5, volume, "sine"],
    [dur, E5, volume, "sine"],
    [dur, C5, volume, "sine"],
    [dur, D5, volume, "sine"],
    [dur * 2, C5, volume, "sine"],
  ]);
}

export function playBoardSound(key) {
  if (isBuddyMuted()) return;
  if (key === "nap") return playNapBeeps();
  if (key === "wake") return playWakeBeeps();
  if (key === "birthday") return playHappyBirthdayBeeps();
  if (key === "alarm") return playAlarmBeeps();
  return playDefaultBeeps();
}
