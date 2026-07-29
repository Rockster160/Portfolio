// Buddy's countdown timer chips — the vertical stack pinned top-left under the
// nav. Server-authoritative: the Timer model fires via Sidekiq and broadcasts,
// so this is purely presentation + reconciliation. It:
//   * hydrates the live list on load / reconnect (GET /buddy/timers)
//   * applies :timers MonitorChannel broadcasts (create/pause/resume/fire/archive)
//   * ticks every 250ms to update the remaining-time readout off end_at
//   * tap a chip → pause/resume; swipe it away → cancel
//   * on a timer firing WHILE open → rings the grub alarm + face loop until a
//     tap anywhere acknowledges (confirms every fired timer)
//   * a timer already fired when the app OPENS counts as acknowledged — we
//     confirm it silently instead of blaring (the away case got a push).

import { startAlarm, stopAlarm, alarmRunning, isBuddyMuted } from "./alarm";

async function apiCall(url, method) {
  const csrfMeta = document.querySelector('meta[name="csrf-token"]');
  const csrf = csrfMeta ? csrfMeta.getAttribute("content") : "";
  const res = await fetch(url, {
    method,
    credentials: "same-origin",
    headers: { "Accept": "application/json", "X-CSRF-Token": csrf },
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  return res.json().catch(() => ({}));
}

function fmt(ms) {
  const total = Math.max(0, Math.round(ms / 1000));
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  const pad = (n) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${pad(m)}:${pad(s)}` : `${m}:${pad(s)}`;
}

// Server-authoritative remaining for a serialized countdown.
function remainingMs(t) {
  if (t.paused_at) return t.paused_remaining_ms ?? 0;
  if (t.end_at) return Math.max(0, Date.parse(t.end_at) - Date.now());
  return t.duration_ms ?? 0;
}

function isFired(t) {
  return !!t.fired_at && !t.confirmed_at;
}
function isPaused(t) {
  return !!t.paused_at;
}

export function initBuddyTimers({ container, hero, isBuddyActiveFn }) {
  if (!container) return null;

  const timers = new Map(); // id → serialized timer
  let pageId = null;
  let tickHandle = 0;
  let ackArmed = false;
  let ackHandler = null;

  const isBuddyActive = () => (isBuddyActiveFn ? isBuddyActiveFn() : true);

  // ---- rendering ----------------------------------------------------------

  function ordered() {
    // Fired first (they need attention), then soonest-to-expire.
    return Array.from(timers.values()).sort((a, b) => {
      const fa = isFired(a) ? 0 : 1;
      const fb = isFired(b) ? 0 : 1;
      if (fa !== fb) return fa - fb;
      return remainingMs(a) - remainingMs(b);
    });
  }

  function render() {
    const list = ordered();
    container.hidden = list.length === 0 || !isBuddyActive();
    container.innerHTML = "";

    list.forEach((t) => {
      const chip = document.createElement("div");
      chip.className = "byte-timer-chip";
      chip.dataset.timerId = t.id;
      chip.dataset.state = isFired(t) ? "fired" : isPaused(t) ? "paused" : "running";
      if (t.color) chip.style.setProperty("--timer-accent", t.color);

      const icon = document.createElement("span");
      icon.className = "byte-timer-icon";
      icon.textContent = isFired(t) ? "⏰" : isPaused(t) ? "⏸" : "⏲";
      chip.appendChild(icon);

      const readout = document.createElement("span");
      readout.className = "byte-timer-readout";
      readout.dataset.readout = t.id;
      readout.textContent = isFired(t) ? "0:00" : fmt(remainingMs(t));
      chip.appendChild(readout);

      if (t.name) {
        const name = document.createElement("span");
        name.className = "byte-timer-name";
        name.textContent = t.name;
        chip.appendChild(name);
      }

      wireChip(chip, t);
      container.appendChild(chip);
    });

    // Any render guarantees the local ticker is live (idempotent). Belt-and-
    // suspenders so a re-render can never leave a running timer frozen because
    // a prior tick self-cleared the interval.
    ensureTicking();
  }

  // Update only the readout text each tick — cheap, no re-layout.
  function tick() {
    let anyRunning = false;
    timers.forEach((t) => {
      if (isFired(t) || isPaused(t)) return;
      anyRunning = true;
      const el = container.querySelector(`[data-readout="${t.id}"]`);
      if (el) el.textContent = fmt(remainingMs(t));
    });
    if (!anyRunning && tickHandle) {
      clearInterval(tickHandle);
      tickHandle = 0;
    }
  }

  function ensureTicking() {
    if (!tickHandle) tickHandle = window.setInterval(tick, 250);
  }

  // ---- interaction: tap = pause/resume, swipe = cancel --------------------

  function wireChip(chip, t) {
    let startX = null;
    let dragging = false;

    chip.addEventListener("pointerdown", (e) => {
      startX = e.clientX;
      dragging = false;
    });
    chip.addEventListener("pointermove", (e) => {
      if (startX == null) return;
      const dx = e.clientX - startX;
      if (Math.abs(dx) > 6) dragging = true;
      if (dragging) chip.style.transform = `translateX(${dx}px)`;
      chip.style.opacity = String(Math.max(0.2, 1 - Math.abs(dx) / 160));
    });
    const finish = (e) => {
      if (startX == null) return;
      const dx = e.clientX - startX;
      startX = null;
      if (dragging && Math.abs(dx) > 90) {
        chip.style.transform = `translateX(${dx > 0 ? 400 : -400}px)`;
        chip.style.opacity = "0";
        cancelTimer(t.id);
        return;
      }
      chip.style.transform = "";
      chip.style.opacity = "";
      if (!dragging) toggleTimer(t);
    };
    chip.addEventListener("pointerup", finish);
    chip.addEventListener("pointercancel", () => {
      startX = null;
      chip.style.transform = "";
      chip.style.opacity = "";
    });
  }

  async function toggleTimer(t) {
    const id = t.id;
    const url = isPaused(t) ? `/buddy/timers/${id}/resume` : `/buddy/timers/${id}/pause`;
    try {
      const updated = await apiCall(url, "POST");
      upsert(updated);
    } catch (e) {
      console.warn("[buddy] timer toggle failed", e);
    }
  }

  async function cancelTimer(id) {
    timers.delete(id);
    render();
    try {
      await apiCall(`/buddy/timers/${id}`, "DELETE");
    } catch (e) {
      console.warn("[buddy] timer cancel failed", e);
    }
  }

  // ---- alarm orchestration ------------------------------------------------

  function firedTimers() {
    return Array.from(timers.values()).filter(isFired);
  }

  // Ring while any timer is fired; a single tap anywhere acknowledges them all.
  function syncAlarm() {
    const fired = firedTimers();
    if (fired.length > 0) {
      if (!alarmRunning()) startAlarm({ hero });
      armAck();
    } else if (alarmRunning()) {
      stopAlarm({ hero });
      disarmAck();
    }
  }

  function armAck() {
    if (ackArmed) return;
    ackArmed = true;
    ackHandler = () => acknowledgeAll();
    // Capture phase so it fires before chip handlers; one real tap silences it.
    document.addEventListener("pointerdown", ackHandler, { capture: true });
  }
  function disarmAck() {
    if (!ackArmed) return;
    ackArmed = false;
    document.removeEventListener("pointerdown", ackHandler, { capture: true });
    ackHandler = null;
  }

  function acknowledgeAll() {
    stopAlarm({ hero });
    disarmAck();
    firedTimers().forEach((t) => confirmTimer(t.id));
  }

  // Silent ack (no alarm) — used for timers found already-fired on open.
  async function confirmTimer(id) {
    try {
      const updated = await apiCall(`/buddy/timers/${id}/confirm`, "POST");
      upsert(updated); // confirmed → drops out of fired state (and often clears)
    } catch (e) {
      console.warn("[buddy] timer confirm failed", e);
    }
  }

  // ---- store mutations ----------------------------------------------------

  function upsert(t) {
    if (!t || t.id == null) return;
    // Confirmed/archived countdowns are done — drop them from the stack.
    if (t.archived_at || (t.confirmed_at && !t.started_at && !t.fired_at)) {
      timers.delete(t.id);
    } else {
      timers.set(t.id, t);
    }
    render();
    ensureTicking();
    syncAlarm();
  }

  // ---- public surface -----------------------------------------------------

  return {
    // Initial + reconnect hydrate. Any timer already fired when we load counts
    // as acknowledged (the person was away and got a push) — confirm it quietly
    // rather than starting the alarm.
    async hydrate() {
      try {
        const data = await apiCall("/buddy/timers", "GET");
        pageId = data.page_id;
        timers.clear();
        (data.timers || []).forEach((t) => timers.set(t.id, t));

        const preFired = firedTimers();
        render();
        ensureTicking();
        if (preFired.length > 0) {
          preFired.forEach((t) => confirmTimer(t.id));
        } else {
          syncAlarm();
        }
      } catch (e) {
        console.warn("[buddy] timer hydrate failed", e);
      }
    },

    // A :timers MonitorChannel broadcast. Ignores timers that aren't Buddy's
    // (the person's regular board timers ride the same per-user stream).
    applyBroadcast(payload) {
      const data = payload?.data || {};
      const t = data.timer;
      if (!t) return;
      if (pageId != null && t.timer_page_id !== pageId) return;
      if (data.reason === "archived") {
        timers.delete(t.id);
        render();
        syncAlarm();
        return;
      }
      upsert(t);
    },

    setActive() {
      render();
    },

    muted: isBuddyMuted,
  };
}
