import { beeps } from "./dashboard/vars";
import { Monitor } from "./dashboard/cells/monitor";
import { Time } from "./dashboard/cells/_time";

document.addEventListener("DOMContentLoaded", () => {
  const container = document.querySelector(".whisper-container");
  if (!container) return;

  const birthDate = container.dataset.birthDate;
  const monitorChannel = container.dataset.monitorChannel;
  const durationsContainer = container.querySelector(".whisper-durations");
  const statusContainer = container.querySelector(".whisper-status");

  let timers = [];
  let completedAlertBeeper = undefined;

  const CIRCUMFERENCE = 2 * Math.PI * 45;

  function playAlertBeeps() {
    // Tamagotchi-style beeps
    const volume = 0.2;
    beeps([
      // triple beep
      [130, 2100, volume, "square"],
      [60, 0, 0, null],
      [130, 2100, volume, "square"],
      [60, 0, 0, null],
      [130, 2100, volume, "square"],

      // pause
      [360, 0, 0, null],

      // triple beep again
      [130, 2100, volume, "square"],
      [60, 0, 0, null],
      [130, 2100, volume, "square"],
      [60, 0, 0, null],
      [130, 2100, volume, "square"],
    ]);
  }

  // Age calculation - date-based, increments on the 14th of each month
  function updateAge() {
    const birth = new Date(birthDate);
    const now = Time.now();

    let totalMonths =
      (now.getFullYear() - birth.getFullYear()) * 12 +
      (now.getMonth() - birth.getMonth());

    if (now.getDate() < birth.getDate()) {
      totalMonths--;
    }

    const years = Math.floor(totalMonths / 12);
    const months = totalMonths % 12;
    const weeks = Math.floor((now - birth) / Time.week());

    let ageStr;
    if (years === 0) {
      ageStr = `${months}m`;
    } else if (months === 0) {
      ageStr = `${years}y`;
    } else {
      ageStr = `${years}y ${months}m`;
    }

    const ageEl = container.querySelector(".whisper-age");
    if (ageEl) {
      ageEl.textContent = `${ageStr} (${weeks}w)`;
    }
  }

  function formatRemaining(seconds) {
    const abs = Math.abs(seconds);
    const m = Math.floor(abs / 60);
    const s = Math.floor(abs % 60);
    const sign = seconds < 0 ? "-" : "";
    return `${sign}${m}:${s.toString().padStart(2, "0")}`;
  }

  function createRingElement(key, label) {
    const ring = document.createElement("div");
    ring.className = "duration-ring";
    ring.dataset.durationKey = key;
    ring.innerHTML = `
      <svg class="ring-svg" viewBox="0 0 100 100">
        <circle class="ring-bg" cx="50" cy="50" r="45" />
        <circle class="ring-progress" cx="50" cy="50" r="45" />
      </svg>
      <div class="ring-content">
        <div class="ring-label">${label || key}</div>
        <div class="ring-timer">0:00</div>
      </div>
    `;
    return ring;
  }

  function syncTimerRings(newTimers) {
    const newKeys = newTimers.map((t) => t.key);
    const existingRings = durationsContainer.querySelectorAll(".duration-ring");

    // Remove rings not in new data
    existingRings.forEach((ring) => {
      if (!newKeys.includes(ring.dataset.durationKey)) {
        ring.remove();
      }
    });

    // Add/reorder rings
    newTimers.forEach((timerData, index) => {
      let ring = durationsContainer.querySelector(
        `[data-duration-key="${timerData.key}"]`,
      );

      if (!ring) {
        // Create new ring
        ring = createRingElement(timerData.key, timerData.label);
      }

      // Update label if changed
      const labelEl = ring.querySelector(".ring-label");
      if (
        labelEl &&
        timerData.label &&
        labelEl.textContent !== timerData.label
      ) {
        labelEl.textContent = timerData.label;
      }

      // Ensure correct order by appending (moves existing or adds new)
      const currentAtIndex = durationsContainer.children[index];
      if (currentAtIndex !== ring) {
        if (currentAtIndex) {
          durationsContainer.insertBefore(ring, currentAtIndex);
        } else {
          durationsContainer.appendChild(ring);
        }
      }
    });

    // Update timers array
    timers = newTimers;
  }

  function updateDurationRing(timerData) {
    const ringEl = durationsContainer.querySelector(
      `[data-duration-key="${timerData.key}"]`,
    );
    if (!ringEl) return;

    const nowSec = Math.floor(Time.msSinceEpoch() / 1000);
    const last = timerData.last || nowSec;
    const next = timerData.next || nowSec;

    const totalDuration = next - last;
    const elapsed = nowSec - last;
    const remaining = next - nowSec;

    const progress =
      totalDuration > 0 ? Math.min(elapsed / totalDuration, 1) : 1;

    const progressCircle = ringEl.querySelector(".ring-progress");
    if (progressCircle) {
      const offset = CIRCUMFERENCE * progress;
      progressCircle.setAttribute("stroke-dasharray", CIRCUMFERENCE);
      progressCircle.setAttribute("stroke-dashoffset", offset);

      if (remaining <= 0) {
        progressCircle.classList.add("overdue");
      } else {
        progressCircle.classList.remove("overdue");
      }
    }

    const timerEl = ringEl.querySelector(".ring-timer");
    if (timerEl) {
      timerEl.textContent = formatRemaining(remaining);
      if (remaining <= 0) {
        timerEl.classList.add("overdue");
      } else {
        timerEl.classList.remove("overdue");
      }
    }

    return remaining;
  }

  function updateAllDurations() {
    let anyOverdue = false;

    timers.forEach((timerData) => {
      const remaining = updateDurationRing(timerData);
      if (remaining !== undefined && remaining <= 0) {
        anyOverdue = true;
      }
    });

    // Manage alert beeper
    if (anyOverdue && !completedAlertBeeper) {
      playAlertBeeps();
      completedAlertBeeper = setInterval(playAlertBeeps, Time.minutes(5));
    } else if (!anyOverdue && completedAlertBeeper) {
      clearInterval(completedAlertBeeper);
      completedAlertBeeper = undefined;
    }
  }

  function updateStatus(status) {
    if (statusContainer) {
      statusContainer.textContent = status || "";
    }
  }

  Monitor.subscribe(monitorChannel, {
    connected: function () {
      this.refresh();
    },
    received: function (data) {
      const monitorData = data?.data;
      if (!monitorData) return;

      if (monitorData.status !== undefined) {
        updateStatus(monitorData.status);
      }

      if (Array.isArray(monitorData.timers)) {
        syncTimerRings(monitorData.timers);
        updateAllDurations();
      }
    },
  });

  // Start timers
  updateAge();
  setInterval(updateAge, Time.hour());
  setInterval(updateAllDurations, Time.second());
  updateAllDurations();
});
