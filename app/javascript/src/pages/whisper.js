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
  let wasQuietActive = false;

  const CIRCUMFERENCE = 2 * Math.PI * 45;

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

  let openVomitModal = () => {};

  // Action menu (top-right dropdown)
  const menu = container.querySelector("[data-whisper-menu]");
  if (menu) {
    const menuToggle = menu.querySelector(".whisper-menu-toggle");
    const menuItems = menu.querySelector(".whisper-menu-items");

    menuToggle.addEventListener("click", (e) => {
      e.stopPropagation();
      menuItems.classList.toggle("hidden");
    });

    document.addEventListener("click", (e) => {
      if (!menu.contains(e.target)) menuItems.classList.add("hidden");
    });

    menu.querySelectorAll("[data-trigger]").forEach((btn) => {
      btn.addEventListener("click", async (e) => {
        e.stopPropagation();
        const scope = btn.dataset.trigger;
        btn.disabled = true;
        try {
          await fetch(`/jil/trigger/${encodeURIComponent(scope)}`, {
            method: "POST",
            credentials: "same-origin",
            headers: { "Content-Type": "application/json" },
            body: "{}",
          });
        } finally {
          btn.disabled = false;
          menuItems.classList.add("hidden");
        }
      });
    });

    const vomitBtn = menu.querySelector('[data-action="log-vomit"]');
    if (vomitBtn) {
      vomitBtn.addEventListener("click", (e) => {
        e.stopPropagation();
        menuItems.classList.add("hidden");
        openVomitModal();
      });
    }
  }

  const vomitModal = container.querySelector("[data-whisper-vomit-modal]");
  if (vomitModal) {
    const form = vomitModal.querySelector("[data-vomit-form]");
    const notesEl = vomitModal.querySelector("[data-vomit-notes]");
    const tsEl = vomitModal.querySelector("[data-vomit-timestamp]");
    const submitBtn = form.querySelector(".whisper-modal-submit");

    function localNowString() {
      const d = new Date();
      const pad = (n) => String(n).padStart(2, "0");
      return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
    }

    openVomitModal = function() {
      notesEl.value = "";
      tsEl.value = localNowString();
      vomitModal.classList.remove("hidden");
      setTimeout(() => notesEl.focus(), 50);
    };

    function closeVomitModal() {
      vomitModal.classList.add("hidden");
    }

    vomitModal.querySelectorAll("[data-vomit-dismiss]").forEach((el) => {
      el.addEventListener("click", (e) => {
        e.preventDefault();
        e.stopPropagation();
        closeVomitModal();
      });
    });

    document.addEventListener("keydown", (e) => {
      if (e.key === "Escape" && !vomitModal.classList.contains("hidden")) {
        closeVomitModal();
      }
    });

    form.addEventListener("submit", async (e) => {
      e.preventDefault();
      submitBtn.disabled = true;
      try {
        const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content || "";
        const res = await fetch("/whisper/log_vomit", {
          method: "POST",
          credentials: "same-origin",
          headers: {
            "Content-Type": "application/json",
            "X-CSRF-Token": csrfToken,
          },
          body: JSON.stringify({ notes: notesEl.value, timestamp: tsEl.value }),
        });
        if (!res.ok) throw new Error(`Log vomit failed: ${res.status}`);
        closeVomitModal();
      } catch (err) {
        console.error(err);
        alert("Failed to log. Try again.");
      } finally {
        submitBtn.disabled = false;
      }
    });
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
    const quietActive = isQuietModeActive();

    // Display only: a timer running out makes no sound here. The sounds go to
    // the Whisper board, sent there by the tasks that own them.
    timers.forEach((timerData) => {
      if (timerMode === "clock") updateClockDisplay(timerData);
      else updateDurationRing(timerData);
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
