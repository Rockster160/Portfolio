import { beeps } from "./dashboard/vars";
import { Monitor } from "./dashboard/cells/monitor";
import { Time } from "./dashboard/cells/_time";
import {
  checkWhisperNotificationStatus,
  registerWhisperNotifications,
  unregisterWhisperNotifications,
} from "./whisper_push";

document.addEventListener("DOMContentLoaded", () => {
  const container = document.querySelector(".whisper-container");
  if (!container) return;

  const monitorChannel = container.dataset.monitorChannel;
  const birthDateMs = 1760432400000; // October 14, 2025 at 3am Denver (MDT = UTC-6)
  const birth = new Date(birthDateMs);
  const durationsContainer = container.querySelector(".whisper-durations");
  const statusContainer = container.querySelector(".whisper-status");
  const timerMode = params.timer || "ring"; // "ring" (default) or "clock"

  let timers = [];
  let timerAlarms = {}; // Per-timer alarm intervals

  const CIRCUMFERENCE = 2 * Math.PI * 45;

  const volume = 0.9;

  let shouldPlayHappyBirthday = false;
  let lastWeeks = null;
  let lastStatus = null;

  // Mute functionality
  const muteBtn = container.querySelector(".whisper-mute-toggle");
  let isMuted = localStorage.getItem("whisper-muted") === "true";

  function updateMuteButton() {
    if (muteBtn) {
      muteBtn.classList.toggle("muted", isMuted);
    }
  }

  function toggleMute() {
    isMuted = !isMuted;
    localStorage.setItem("whisper-muted", isMuted);
    updateMuteButton();
  }

  if (muteBtn) {
    muteBtn.addEventListener("click", toggleMute);
    updateMuteButton();
  }

  // Notification toggle functionality
  const notifyBtn = container.querySelector(".whisper-notify-toggle");

  async function updateNotifyButton() {
    if (!notifyBtn) return;

    const status = await checkWhisperNotificationStatus();
    notifyBtn.classList.remove(
      "hidden",
      "subscribed",
      "unsubscribed",
      "denied",
      "unsupported",
    );
    notifyBtn.classList.add(status);

    switch (status) {
      case "subscribed":
        notifyBtn.title = "Notifications enabled (click to disable)";
        break;
      case "denied":
        notifyBtn.title = "Notifications blocked by browser";
        break;
      case "unsupported":
        notifyBtn.title = "Notifications not supported";
        break;
      default:
        notifyBtn.title = "Enable notifications";
    }
  }

  async function toggleNotifications() {
    const status = await checkWhisperNotificationStatus();

    if (status === "denied") {
      alert(
        "Notifications are blocked. Please enable them in your browser settings.",
      );
      return;
    }

    if (status === "subscribed") {
      await unregisterWhisperNotifications();
    } else {
      await registerWhisperNotifications();
    }

    updateNotifyButton();
  }

  if (notifyBtn) {
    notifyBtn.addEventListener("click", toggleNotifications);
    updateNotifyButton();
  }

  function playDefaultBeeps() {
    if (isMuted) return;

    beeps([
      [300, 262, volume - 0.2, "sine"],
      [350, 330, volume - 0.1, "sine"],
      [350, 392, volume - 0.15, "sine"],
      [350, 330, volume - 0.1, "sine"],
      [400, 262, volume - 0.2, "sine"],
    ]);
  }

  function playNapBeeps() {
    if (isMuted) return;
    beeps([
      [400, 392, volume, "sine"],
      [400, 349, volume, "sine"],
      [400, 330, volume - 0.01, "sine"],
      [400, 294, volume - 0.02, "sine"],
      [600, 262, volume - 0.03, "sine"],
    ]);
  }

  function playWakeBeeps() {
    if (isMuted) return;
    beeps([
      [400, 262, volume - 0.03, "sine"],
      [400, 294, volume - 0.02, "sine"],
      [400, 330, volume - 0.01, "sine"],
      [400, 349, volume, "sine"],
      [600, 392, volume, "sine"],
    ]);
  }

  function playHappyBirthdayBeeps() {
    if (isMuted) return;
    // Happy Birthday melody
    // Notes: G4=392, A4=440, B4=494, C5=523, D5=587, E5=659, F5=698, G5=784
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

  function playAlertForKey(key) {
    if (key === "nap") {
      playNapBeeps();
    } else if (key === "wake") {
      playWakeBeeps();
    } else {
      playDefaultBeeps();
    }
  }

  function updateAge() {
    const nowMs = Time.msSinceEpoch();
    const now = new Date(nowMs);
    const elapsedMs = nowMs - birthDateMs;

    const weeks = Math.floor(elapsedMs / Time.week());

    let totalMonths =
      (now.getFullYear() - birth.getFullYear()) * 12 +
      (now.getMonth() - birth.getMonth());
    if (now.getDate() < birth.getDate()) {
      totalMonths--;
    }
    const years = Math.floor(totalMonths / 12);
    const months = totalMonths % 12;

    // Set birthday flag when weeks changes
    if (lastWeeks !== null && weeks > lastWeeks) {
      shouldPlayHappyBirthday = true;
    }
    lastWeeks = weeks;

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
    const m = Math.ceil(abs / 60);
    const s = Math.ceil(abs % 60);
    const sign = seconds < 0 && m != 0 ? "-" : "";

    if (seconds > 0 && seconds < 60) {
      return `:${s}s`;
    }
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
    const overdueKeys = new Set();

    timers.forEach((timerData) => {
      const remaining =
        timerMode === "clock"
          ? updateClockDisplay(timerData)
          : updateDurationRing(timerData);
      if (remaining !== undefined && remaining <= 0) {
        overdueKeys.add(timerData.key);
      }
    });

    // Manage per-timer alarms
    overdueKeys.forEach((key) => {
      if (!timerAlarms[key]) {
        playAlertForKey(key);
        timerAlarms[key] = setInterval(
          () => playAlertForKey(key),
          Time.minutes(5),
        );
      }
    });

    // Clear alarms for timers no longer overdue
    Object.keys(timerAlarms).forEach((key) => {
      if (!overdueKeys.has(key)) {
        clearInterval(timerAlarms[key]);
        delete timerAlarms[key];
      }
    });
  }

  function updateStatus(status) {
    if (statusContainer) {
      statusContainer.textContent = status || "";
    }

    // Play happy birthday when status changes to awake on her birthday
    const statusChanged = status !== lastStatus;
    const isAwake = /awake/i.test(status);
    if (statusChanged && isAwake && shouldPlayHappyBirthday) {
      shouldPlayHappyBirthday = false;
      playHappyBirthdayBeeps();
    }
    lastStatus = status;
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
  setInterval(updateAge, Time.minute());
  setInterval(updateAllDurations, Time.second());
  updateAllDurations();
});
