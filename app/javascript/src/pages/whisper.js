import { beeps } from "./dashboard/vars";
import { Monitor } from "./dashboard/cells/monitor";
import { Time } from "./dashboard/cells/_time";
import {
  checkWhisperNotificationStatus,
  registerWhisperNotifications,
  unregisterWhisperNotifications,
  ensureWhisperServiceWorker,
} from "./whisper_push";

document.addEventListener("DOMContentLoaded", async () => {
  const container = document.querySelector(".whisper-container");
  if (!container) return;

  // Check subscription and recover if needed on page load
  const initialStatus = await ensureWhisperServiceWorker();

  const monitorChannel = container.dataset.monitorChannel;
  const birthDateMs = 1760432400000; // October 14, 2025 at 3am Denver (MDT = UTC-6)
  const birth = new Date(birthDateMs);
  const durationsContainer = container.querySelector(".whisper-durations");
  const statusContainer = container.querySelector(".whisper-status");
  const timerMode = params.timer || "ring"; // "ring" (default) or "clock"

  let timers = [];
  let timerAlarms = {}; // Per-timer alarm intervals
  let wasQuietActive = false;

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

  async function updateNotifyButton(existingStatus = null) {
    if (!notifyBtn) return;

    const status = existingStatus || (await checkWhisperNotificationStatus());
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
    updateNotifyButton(initialStatus);

    // Check and recover subscription when user returns to app
    document.addEventListener("visibilitychange", async () => {
      if (document.visibilityState === "visible") {
        const status = await ensureWhisperServiceWorker();
        updateNotifyButton(status);
      }
    });
  }

  function playDefaultBeeps() {
    if (isMuted) return;

    beeps([
      [250, 262, volume - 0.2, "sine"],
      [300, 330, volume - 0.1, "sine"],
      [300, 392, volume - 0.15, "sine"],
      [300, 330, volume - 0.1, "sine"],
      [350, 262, volume - 0.2, "sine"],
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
    const birthTimeOfDay = birth.getHours() * 60 + birth.getMinutes();
    const nowTimeOfDay = now.getHours() * 60 + now.getMinutes();
    if (
      now.getDate() < birth.getDate() ||
      (now.getDate() === birth.getDate() && nowTimeOfDay < birthTimeOfDay)
    ) {
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
    if (years < 1) {
      // Before 1 year: show months (weeks)
      ageStr = `${totalMonths}m (${weeks}w)`;
    } else if (years < 2) {
      // 1-2 years: show years (total months)
      ageStr = `${years}y (${totalMonths}m)`;
    } else {
      // 2+ years: show years and remainder months
      ageStr = months === 0 ? `${years}y` : `${years}y ${months}m`;
    }

    const ageEl = container.querySelector(".whisper-age");
    if (ageEl) {
      ageEl.textContent = ageStr;
    }
  }

  function formatRemaining(seconds) {
    if (seconds > 0 && seconds <= 60) {
      return `:${Math.ceil(seconds)}s`;
    }

    const abs = Math.abs(seconds);
    const m = seconds < 0 ? Math.floor(abs / 60) : Math.ceil(abs / 60);
    const sign = seconds < 0 && m !== 0 ? "-" : "";

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

  function isQuietModeActive() {
    const quietTimer = timers.find((t) => t.key === "quiet");
    if (!quietTimer) return false;
    const nowSec = Math.floor(Time.msSinceEpoch() / 1000);
    const remaining = (quietTimer.next || nowSec) - nowSec;
    return remaining > 0;
  }

  function updateAllDurations() {
    const overdueKeys = new Set();
    const quietActive = isQuietModeActive();

    timers.forEach((timerData) => {
      const remaining =
        timerMode === "clock"
          ? updateClockDisplay(timerData)
          : updateDurationRing(timerData);
      if (remaining !== undefined && remaining <= 0) {
        overdueKeys.add(timerData.key);
      }
    });

    // Manage per-timer alarms (suppressed during quiet mode)
    overdueKeys.forEach((key) => {
      if (key === "quiet" || quietActive) return;
      if (!timerAlarms[key]) {
        playAlertForKey(key);
        timerAlarms[key] = setInterval(
          () => playAlertForKey(key),
          Time.minutes(5),
        );
      }
    });

    // Clear alarms for timers no longer overdue, or all alarms during quiet mode
    Object.keys(timerAlarms).forEach((key) => {
      if (!overdueKeys.has(key) || quietActive) {
        clearInterval(timerAlarms[key]);
        delete timerAlarms[key];
      }
    });

    // Grey out non-quiet rings during quiet mode
    durationsContainer.querySelectorAll(".duration-ring").forEach((ring) => {
      ring.classList.toggle("quieted", quietActive);
    });

    // Re-sync when quiet mode ends
    if (wasQuietActive && !quietActive) {
      durationMonitor.refresh();
    }
    wasQuietActive = quietActive;
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

  const durationMonitor = Monitor.subscribe(monitorChannel, {
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
