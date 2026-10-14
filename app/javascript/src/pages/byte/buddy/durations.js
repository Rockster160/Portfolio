// Whisper duration rings, on the board. The wall tablet that used to run the
// Whisper PWA is now this board, so it shows the same status rings — how long
// she has been out, how long until the next nap, a quiet window, a kennel
// check. Server-authoritative: Jil task 229 "Whisper Duration Monitor"
// broadcasts { status, timers: [{ key, last, next }], sound? } on the
// "whisper-durations" channel; this is pure presentation off that stream.
//
// A faithful port of the ring half of pages/whisper.js — same geometry (r=45 in
// a 100 viewBox), same readout (whole minutes, then :Ns in the final minute,
// negative when overdue), same per-key states (overdue pulse, quiet greys the
// others, kennel maroon). Two deliberate differences:
//   * NO per-overdue auto-alarm. Whisper nagged when a ring ran out; the board
//     only makes a sound when a Jil task explicitly broadcasts { sound } (which
//     we hand to playBoardSound). The rings are a readout, not an alarm.
//   * The row hides itself when there are no timers (sleeping / gone broadcasts
//     an empty list), so an idle board shows the pet alone.
//
// This is entirely separate from buddy/timers.js (the countdown-timer banner) —
// different data, different element, neither touches the other.

import { Monitor } from "../../dashboard/cells/monitor";
import { Time } from "../../dashboard/cells/_time";
import { playBoardSound } from "./sound";
import { boardTags, groupsOverlap } from "./board_scope";

const CIRCUMFERENCE = 2 * Math.PI * 45;

// Whole minutes while more than a minute is left, a seconds count in the final
// minute, and a negative minute count once overdue — read from across the room.
function formatRemaining(seconds) {
  if (seconds > 0 && seconds <= 60) return `:${Math.ceil(seconds)}s`;
  const abs = Math.abs(seconds);
  const m = seconds < 0 ? Math.floor(abs / 60) : Math.ceil(abs / 60);
  const sign = seconds < 0 && m !== 0 ? "-" : "";
  return `${sign}${m}m`;
}

export function initBoardDurations({ container, app }) {
  if (!container) return { refresh() {} };

  const tags = boardTags(app);
  let timers = [];
  let wasQuietActive = false;
  // Whether the feed's most recent groups overlap what this board watches. The
  // sound-only broadcasts carry no groups, so they ride this last-known verdict
  // from the duration broadcasts (229), which run on every whisper event.
  let channelMatches = false;

  function createRingElement(key, label) {
    const ring = document.createElement("div");
    ring.className = "duration-ring";
    ring.dataset.durationKey = key;
    ring.innerHTML = `
      <svg class="ring-svg" viewBox="0 0 100 100" aria-hidden="true">
        <circle class="ring-bg" cx="50" cy="50" r="45"></circle>
        <circle class="ring-progress" cx="50" cy="50" r="45"></circle>
      </svg>
      <div class="ring-content">
        <div class="ring-label">${label || key}</div>
        <div class="ring-timer">0m</div>
      </div>
    `;
    return ring;
  }

  // Reconcile the row to the new list by key: drop rings no longer present, add
  // new ones, and move each into its broadcast order.
  function syncTimers(newTimers) {
    const newKeys = newTimers.map((t) => t.key);

    container.querySelectorAll(".duration-ring").forEach((item) => {
      if (!newKeys.includes(item.dataset.durationKey)) item.remove();
    });

    newTimers.forEach((timerData, index) => {
      let item = container.querySelector(
        `[data-duration-key="${timerData.key}"]`,
      );
      if (!item) item = createRingElement(timerData.key, timerData.label);

      const labelEl = item.querySelector(".ring-label");
      if (labelEl && timerData.label && labelEl.textContent !== timerData.label) {
        labelEl.textContent = timerData.label;
      }

      const atIndex = container.children[index];
      if (atIndex !== item) {
        if (atIndex) container.insertBefore(item, atIndex);
        else container.appendChild(item);
      }
    });

    timers = newTimers;
    container.hidden = timers.length === 0;
  }

  function updateDurationRing(timerData) {
    const ringEl = container.querySelector(
      `[data-duration-key="${timerData.key}"]`,
    );
    if (!ringEl) return;

    const nowSec = Math.floor(Time.msSinceEpoch() / 1000);
    const last = timerData.last || nowSec;
    const next = timerData.next || nowSec;
    const totalDuration = next - last;
    const elapsed = nowSec - last;
    const remaining = next - nowSec;
    const progress = totalDuration > 0 ? Math.min(elapsed / totalDuration, 1) : 1;

    const progressCircle = ringEl.querySelector(".ring-progress");
    if (progressCircle) {
      progressCircle.setAttribute("stroke-dasharray", CIRCUMFERENCE);
      progressCircle.setAttribute("stroke-dashoffset", CIRCUMFERENCE * progress);
      progressCircle.classList.toggle("overdue", remaining <= 0);
    }

    const timerEl = ringEl.querySelector(".ring-timer");
    if (timerEl) {
      timerEl.textContent = formatRemaining(remaining);
      timerEl.classList.toggle("overdue", remaining <= 0);
    }

    return remaining;
  }

  function isQuietModeActive() {
    const quietTimer = timers.find((t) => t.key === "quiet");
    if (!quietTimer) return false;
    const nowSec = Math.floor(Time.msSinceEpoch() / 1000);
    return (quietTimer.next || nowSec) - nowSec > 0;
  }

  function updateAllDurations() {
    const quietActive = isQuietModeActive();
    timers.forEach((timerData) => updateDurationRing(timerData));
    // Quiet mode greys everything but the quiet (and kennel) rings — the house
    // is meant to be still, so the other countdowns recede.
    container.querySelectorAll(".duration-ring").forEach((ring) => {
      ring.classList.toggle("quieted", quietActive);
    });
    if (wasQuietActive && !quietActive) durationMonitor.refresh();
    wasQuietActive = quietActive;
  }

  const durationMonitor = Monitor.subscribe("whisper-durations", {
    connected() {
      this.refresh();
    },
    received(data) {
      const monitorData = data?.data;
      if (!monitorData) return;
      // A broadcast that names its groups re-decides whether this board is one
      // the feed is aimed at. The board only shows the rings and plays the
      // sounds when its watched groups overlap — otherwise it stays dark, even
      // though every board on the account hears the same channel.
      if (monitorData.groups !== undefined) {
        channelMatches = groupsOverlap(monitorData.groups, tags);
      }
      // status is intentionally ignored — the pet's own face carries the mood.
      if (monitorData.sound && channelMatches) playBoardSound(monitorData.sound);
      if (Array.isArray(monitorData.timers)) {
        // Not ours → clear the row rather than drawing someone else's timers.
        syncTimers(channelMatches ? monitorData.timers : []);
        updateAllDurations();
      }
    },
  });

  setInterval(updateAllDurations, Time.second());
  updateAllDurations();

  return { refresh: () => durationMonitor.refresh() };
}
