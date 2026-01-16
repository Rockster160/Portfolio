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
  const timerMode = params.timer || "ring"; // "ring" (default) or "clock"

  let timers = [];
  let completedAlertBeeper = undefined;

  const CIRCUMFERENCE = 2 * Math.PI * 45;

  function playAlertBeeps() {
    const swell = [
      [60, 440, 0.01, "sine"],
      [60, 440, 0.03, "sine"],
      [60, 440, 0.06, "sine"],
      [60, 440, 0.09, "sine"],
      [60, 440, 0.07, "sine"],
      [60, 440, 0.04, "sine"],
    ];

    beeps([
      ...swell,
      [200, 0, 0, null],
      ...swell,
      [500, 0, 0, null],
      ...swell,
      [200, 0, 0, null],
      ...swell,
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
    // return `${sign}${m}:${s.toString().padStart(2, "0")}`;
    return `${sign}${m}m`;
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
        <div class="ring-timer">0m</div>
      </div>
    `;
    return ring;
  }

  function createClockElement(key, label) {
    const item = document.createElement("div");
    item.className = "duration-clock";
    item.dataset.durationKey = key;
    item.innerHTML = `
      <span class="clock-label">${label || key}:</span>
      <span class="clock-time"></span>
    `;
    return item;
  }

  function syncTimers(newTimers) {
    const newKeys = newTimers.map((t) => t.key);
    const itemClass =
      timerMode === "clock" ? ".duration-clock" : ".duration-ring";
    const labelClass = timerMode === "clock" ? ".clock-label" : ".ring-label";
    const existingItems = durationsContainer.querySelectorAll(itemClass);

    // Remove items not in new data
    existingItems.forEach((item) => {
      if (!newKeys.includes(item.dataset.durationKey)) {
        item.remove();
      }
    });

    // Add/reorder items
    newTimers.forEach((timerData, index) => {
      let item = durationsContainer.querySelector(
        `[data-duration-key="${timerData.key}"]`,
      );

      if (!item) {
        // Create new item based on mode
        item =
          timerMode === "clock"
            ? createClockElement(timerData.key, timerData.label)
            : createRingElement(timerData.key, timerData.label);
      }

      // Update label if changed
      const labelEl = item.querySelector(labelClass);
      if (labelEl && timerData.label) {
        const expectedLabel =
          timerMode === "clock" ? `${timerData.label}:` : timerData.label;
        if (labelEl.textContent !== expectedLabel) {
          labelEl.textContent = expectedLabel;
        }
      }

      // Ensure correct order by appending (moves existing or adds new)
      const currentAtIndex = durationsContainer.children[index];
      if (currentAtIndex !== item) {
        if (currentAtIndex) {
          durationsContainer.insertBefore(item, currentAtIndex);
        } else {
          durationsContainer.appendChild(item);
        }
      }
    });

    // Update timers array
    timers = newTimers;
  }

  function updateClockDisplay(timerData) {
    const clockEl = durationsContainer.querySelector(
      `[data-duration-key="${timerData.key}"]`,
    );
    if (!clockEl) return;

    const nowSec = Math.floor(Time.msSinceEpoch() / 1000);
    const next = timerData.next || nowSec;
    const remaining = next - nowSec;

    const timeEl = clockEl.querySelector(".clock-time");
    if (timeEl) {
      timeEl.textContent = Time.local(next * 1000);
      if (remaining <= 0) {
        timeEl.classList.add("overdue");
      } else {
        timeEl.classList.remove("overdue");
      }
    }

    return remaining;
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
      const remaining =
        timerMode === "clock"
          ? updateClockDisplay(timerData)
          : updateDurationRing(timerData);
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
        syncTimers(monitorData.timers);
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
