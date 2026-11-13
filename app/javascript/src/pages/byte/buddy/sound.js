// Board sounds, played exactly as Jil sent them. A task builds a Sound out of
// beep blocks and sends it to one board by name (Buddy.sound, or a yell's
// `sound`); the notes arrive here in the shape `beeps` takes,
//   [[milliseconds, hertz, volume, wave], ...]
// with a rest as a note at 0 Hz. No tune lives in this file: what a sound is
// belongs to the task that plays it.
//
// Honours the pet's own mute (buddy:muted) so the wall tablet's "shush" quiets
// a Jil sound the same way it quiets the timer alarm; the two share the key.

import { beeps } from "../../dashboard/vars";
import { isBuddyMuted } from "./alarm";

export function playBoardSound(notes) {
  if (isBuddyMuted()) return;
  if (!Array.isArray(notes) || notes.length === 0) return;

  beeps(notes.filter((note) => Array.isArray(note)));
}
