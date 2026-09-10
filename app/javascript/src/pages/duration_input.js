// Live readback under every duration box: type "1:32" and the line underneath
// says "1h 32m · 92 minutes", which is what will actually be stored.
//
// Delegated from the document rather than bound per input, because the prompt
// page rewrites its own fields on load (task 232 computes a shower Duration,
// 329 pulls one off the workout event) and a field that appeared after this ran
// still has to answer.
import {
  parseDurationMinutes,
  formatDurationHint,
} from "../support/parse_duration.js";

function paintHint(input) {
  const hint = input.parentElement?.querySelector(".prompt-duration-hint");
  if (!hint) return;

  const raw = input.value;
  const minutes = parseDurationMinutes(raw);

  if (minutes == null) {
    // Blank is not a mistake — most of these open empty and stay that way.
    // Something typed that carries no number IS, and it says so, because the
    // alternative is a silent "" landing in the record.
    const unreadable = raw.trim().length > 0;
    hint.textContent = unreadable ? "Can't read that as a duration" : "";
    hint.dataset.unreadable = unreadable ? "true" : "false";
    return;
  }

  hint.textContent = formatDurationHint(minutes);
  hint.dataset.unreadable = "false";
}

function paintAll() {
  document.querySelectorAll(".prompt-duration-input").forEach(paintHint);
}

document.addEventListener("input", (evt) => {
  if (evt.target.classList?.contains("prompt-duration-input")) paintHint(evt.target);
});

document.addEventListener("DOMContentLoaded", paintAll);
// The page fires its load trigger and re-renders the questions, so whatever was
// on screen at DOMContentLoaded is not necessarily what is there a beat later.
window.addEventListener("load", paintAll);
