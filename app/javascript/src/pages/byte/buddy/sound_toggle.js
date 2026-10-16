// The board's speaker, in the corner like the Whisper page's: whether this
// screen can actually make its sounds, and the way to mute them.
//
// Three states, read straight off the browser and the pet's own mute:
//   on       - sound plays.
//   blocked  - the browser is holding sound back until someone touches the
//              page. Any tap lets it go (dashboard/vars.js resumes on the first
//              gesture), this one included, and the icon follows as it lands.
//   muted    - shushed here (buddy:muted, the same key the timer alarm uses).

import { audioState, onAudioStateChange } from "../../dashboard/vars";
import { isBuddyMuted, toggleBuddyMuted } from "./alarm";

const TITLES = {
  on: "Sound on",
  blocked: "Sound is blocked until this screen is tapped",
  muted: "Sound off",
};

export function initSoundToggle({ button, onChange } = {}) {
  if (!button) return null;

  function paint() {
    const state = isBuddyMuted() ? "muted" : audioState() === "running" ? "on" : "blocked";
    button.dataset.state = state;
    button.title = TITLES[state];
    button.setAttribute("aria-label", TITLES[state]);
  }

  // A tap on a blocked speaker is the tap the browser was waiting for; it
  // shouldn't also mute.
  button.addEventListener("click", () => {
    if (button.dataset.state === "blocked") return;

    toggleBuddyMuted();
    paint();
    onChange?.();
  });

  onAudioStateChange(paint);
  paint();

  return { paint };
}
