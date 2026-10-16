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
// others, kennel maroon), and the same sounds: a ring that runs out plays its
// key's tune (the nap ring, the nap sound) and again every five minutes while
// it stays overdue, held during quiet mode; and a Jil task broadcasting
// { sound } plays that one. One deliberate difference: the row hides itself
// when there are no timers (sleeping / gone broadcasts an empty list), so an
// idle board shows the pet alone.
//
// This is entirely separate from buddy/timers.js (the countdown-timer banner) —
// different data, different element, neither touches the other.

import { Monitor } from "../../dashboard/cells/monitor";
import { Time } from "../../dashboard/cells/_time";
import { playBoardSound } from "./sound";
import { boardTags, groupsOverlap, boardOwnerId, feedOwnerMatches } from "./board_scope";

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

export function initBoardDurations({ container, app, onStatus }) {
  if (!container) return { refresh() {}, setTags() {} };

  // Read fresh on every use, not captured once: the watched groups can change
  // live (another device repoints the board), and setTags re-runs the match.
  let tags = boardTags(app);
  // Fixed for the life of the board: who it belongs to. A feed only shows here
  // if it's this owner's, so a shared board stays the owner's while a housemate's
  // own "Whisper" board never picks the owner's feeds up.
  const boardOwner = boardOwnerId(app);
  let timers = [];
  let wasQuietActive = false;
  // The repeating sound for each overdue ring, by key.
  const ringAlarms = {};
  // Whether the feed's most recent groups overlap what this board watches AND it
  // belongs to this board's owner. The sound-only broadcasts carry no groups, so
  // they ride this last-known verdict from the duration broadcasts (229), which
  // run on every whisper event.
  let channelMatches = false;
  // The last broadcast's groups, owner, timers and status, kept so a live tag
  // change can re-decide the match and repaint without waiting for the next one.
  let lastGroups;
  let lastOwnerId;
  let lastTimers = [];
  let lastStatus;

  // Groups overlap AND the feed is this board's owner's — the whole gate, in one
  // place so the broadcast path and a live tag change decide it identically.
  function decideMatch() {
    return groupsOverlap(lastGroups, tags) && feedOwnerMatches(lastOwnerId, boardOwner);
  }

  // Whisper's own state, parsed from the broadcast status string ("Awake ☀️",
  // "Napping 💤", "🛏️ Sleeping", "Gone 👋"), so the board's pet can mirror it.
  function whisperState(status) {
    const s = String(status || "").toLowerCase();
    if (/gone/.test(s)) return "gone";
    if (/sleep|nap/.test(s)) return "asleep";
    if (/awake/.test(s)) return "awake";
    return null;
  }

  // Push the current match + status out to the pet and the rings. Called from a
  // broadcast and from a live tag change, so both paths render identically.
  function reconcile() {
    syncTimers(channelMatches ? lastTimers : []);
    updateAllDurations();
    // Only a board that watches this feed wears Whisper's state; every other
    // board hears the same channel and must ignore it.
    onStatus?.(channelMatches ? whisperState(lastStatus) : null);
  }

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

  // The Whisper page's ring alarms: a ring running out plays its key's sound,
  // then again every five minutes until it's reset. Quiet mode holds them all;
  // the quiet, out and kennel rings count time rather than ask for anything.
  function soundOverdue(overdueKeys, quietActive) {
    overdueKeys.forEach((key) => {
      if (key === "quiet" || key === "out" || key === "kennel" || quietActive) return;
      if (ringAlarms[key]) return;

      playBoardSound(key);
      ringAlarms[key] = setInterval(() => playBoardSound(key), Time.minutes(5));
    });

    Object.keys(ringAlarms).forEach((key) => {
      if (overdueKeys.has(key) && !quietActive) return;

      clearInterval(ringAlarms[key]);
      delete ringAlarms[key];
    });
  }

  function isQuietModeActive() {
    const quietTimer = timers.find((t) => t.key === "quiet");
    if (!quietTimer) return false;
    const nowSec = Math.floor(Time.msSinceEpoch() / 1000);
    return (quietTimer.next || nowSec) - nowSec > 0;
  }

  function updateAllDurations() {
    const quietActive = isQuietModeActive();
    const overdueKeys = new Set();
    timers.forEach((timerData) => {
      const remaining = updateDurationRing(timerData);
      if (remaining !== undefined && remaining <= 0) overdueKeys.add(timerData.key);
    });
    soundOverdue(overdueKeys, quietActive);
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
      // owner_id rides the envelope (stamped server-side for every broadcast),
      // beside the id/channel, not inside the MonitorData payload.
      if (data.owner_id !== undefined) lastOwnerId = data.owner_id;
      // A broadcast that names its groups re-decides whether this board is one
      // the feed is aimed at. The board only shows the rings and plays the
      // sounds when its watched groups overlap AND the feed is its owner's —
      // otherwise it stays dark, even though every board on the account hears
      // the same channel.
      if (monitorData.groups !== undefined) lastGroups = monitorData.groups;
      channelMatches = decideMatch();
      if (monitorData.status !== undefined) lastStatus = monitorData.status;
      if (Array.isArray(monitorData.timers)) lastTimers = monitorData.timers;
      if (monitorData.sound && channelMatches) playBoardSound(monitorData.sound);
      // A status-only or sound-only broadcast still re-asserts the pet's state.
      reconcile();
    },
  });

  setInterval(updateAllDurations, Time.second());
  updateAllDurations();

  return {
    refresh: () => durationMonitor.refresh(),
    // The watched groups changed under us (the board was repointed, here or on
    // another device). Re-decide the match against the last broadcast and
    // repaint — no need to wait for the feed to speak again.
    setTags(next) {
      tags = Array.isArray(next) ? next.map((t) => String(t).toLowerCase()) : [];
      if (lastGroups !== undefined) channelMatches = decideMatch();
      reconcile();
    },
  };
}
