// Status rings on the board: countdowns a Jil task keeps up to date, each a
// ring that fills as its time runs. Server-authoritative: a task broadcasts
// { timers: [{ key, label, last, next, sound?, hush?, color? }], groups } on the
// "board-rings" channel and this is pure presentation off that stream.
//
// Geometry is r=45 in a 100 viewBox. The readout is whole minutes, then :Ns in
// the final minute, negative once overdue. Everything a ring DOES comes with it,
// so nothing here knows what any ring is for:
//   sound - the tune it plays when it runs out (see buddy/sound.js), and again
//           every five minutes while it stays overdue. None means it's silent.
//   hush  - while it is counting, the board is hushed: every other ring greys
//           and their sounds are held. When it ends the feed is asked again.
//   color - its own colour, kept through a hush and never pulsing when overdue.
// The row hides itself when there are no timers, so an idle board shows the
// pet alone.
//
// This is entirely separate from buddy/timers.js (the countdown-timer banner) —
// different data, different element, neither touches the other.

import { Monitor } from "../../dashboard/cells/monitor";
import { Time } from "../../dashboard/cells/_time";
import { playBoardSound } from "./sound";
import { boardTags, groupsOverlap, boardOwnerId, feedOwnerMatches } from "./board_scope";

const CHANNEL = "board-rings";
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

export function initBoardRings({ container, app }) {
  if (!container) return { refresh() {}, setTags() {} };

  // Read fresh on every use, not captured once: the watched groups can change
  // live (another device repoints the board), and setTags re-runs the match.
  let tags = boardTags(app);
  // Fixed for the life of the board: who it belongs to. A feed only shows here
  // if it's this owner's, so a shared board stays the owner's while a housemate's
  // own board watching the same group never picks the owner's feeds up.
  const boardOwner = boardOwnerId(app);
  let timers = [];
  let wasHushed = false;
  // The repeating sound for each overdue ring, by key.
  const ringAlarms = {};
  // Whether the feed's most recent groups overlap what this board watches AND it
  // belongs to this board's owner.
  let channelMatches = false;
  // The last broadcast's groups, owner and timers, kept so a live tag change can
  // re-decide the match and repaint without waiting for the next one.
  let lastGroups;
  let lastOwnerId;
  let lastTimers = [];

  // Groups overlap AND the feed is this board's owner's — the whole gate, in one
  // place so the broadcast path and a live tag change decide it identically.
  function decideMatch() {
    return groupsOverlap(lastGroups, tags) && feedOwnerMatches(lastOwnerId, boardOwner);
  }

  function reconcile() {
    syncTimers(channelMatches ? lastTimers : []);
    updateAllRings();
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

      // A ring with a colour of its own wears it, and keeps it through a hush.
      if (timerData.color) {
        item.dataset.ringColor = "true";
        item.style.setProperty("--ring-color", timerData.color);
      } else {
        delete item.dataset.ringColor;
        item.style.removeProperty("--ring-color");
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

  function updateRing(timerData) {
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

  // A ring that runs out plays its own sound, then again every five minutes
  // until it's reset. A hush holds them all.
  function soundOverdue(overdue, hushed) {
    overdue.forEach((timerData) => {
      if (!timerData.sound || hushed || ringAlarms[timerData.key]) return;

      playBoardSound(timerData.sound);
      ringAlarms[timerData.key] = setInterval(() => playBoardSound(timerData.sound), Time.minutes(5));
    });

    const sounding = new Set(overdue.filter((t) => t.sound).map((t) => t.key));
    Object.keys(ringAlarms).forEach((key) => {
      if (sounding.has(key) && !hushed) return;

      clearInterval(ringAlarms[key]);
      delete ringAlarms[key];
    });
  }

  // The rings hushing the board right now: ones that say so and are still
  // counting.
  function hushingKeys() {
    const nowSec = Math.floor(Time.msSinceEpoch() / 1000);
    return new Set(
      timers.filter((t) => t.hush && (t.next || nowSec) - nowSec > 0).map((t) => t.key),
    );
  }

  function updateAllRings() {
    const hushing = hushingKeys();
    const hushed = hushing.size > 0;
    const overdue = [];
    timers.forEach((timerData) => {
      const remaining = updateRing(timerData);
      if (remaining !== undefined && remaining <= 0) overdue.push(timerData);
    });
    soundOverdue(overdue, hushed);
    // A hush greys everything but the hushing rings themselves and any ring
    // with its own colour, so the other countdowns recede.
    container.querySelectorAll(".duration-ring").forEach((ring) => {
      const keeps = hushing.has(ring.dataset.durationKey) || ring.dataset.ringColor;
      ring.classList.toggle("quieted", hushed && !keeps);
    });
    if (wasHushed && !hushed) ringMonitor.refresh();
    wasHushed = hushed;
  }

  const ringMonitor = Monitor.subscribe(CHANNEL, {
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
      // the feed is aimed at. The board only shows the rings when its watched
      // groups overlap AND the feed is its owner's — otherwise it stays dark,
      // even though every board on the account hears the same channel.
      if (monitorData.groups !== undefined) lastGroups = monitorData.groups;
      channelMatches = decideMatch();
      if (Array.isArray(monitorData.timers)) lastTimers = monitorData.timers;
      reconcile();
    },
  });

  setInterval(updateAllRings, Time.second());
  updateAllRings();

  return {
    refresh: () => ringMonitor.refresh(),
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
