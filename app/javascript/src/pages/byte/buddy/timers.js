// Buddy's countdown timer chips — the vertical stack pinned top-left under the
// nav. Server-authoritative: the Timer model fires via Sidekiq and broadcasts,
// so this is purely presentation + reconciliation. It:
//   * hydrates the live list on load / reconnect (GET /buddy/timers)
//   * applies :timers MonitorChannel broadcasts (create/pause/resume/fire/archive)
//   * ticks every 250ms to update the remaining-time readout off end_at
//   * tap a chip → pause/resume, or cancel if it's the one ringing;
//     its × → cancel. Either way the SERVER decides when it goes.
//
//     The × replaced a SWIPE, which depended on pointer capture: when that
//     did not take, the chip was left sitting wherever it had been dragged
//     with the timer still running - it looked cancelled and nothing had been
//     sent.
//   * on a timer reaching end_at WHILE open → rings the grub alarm + face loop
//     until a tap anywhere acknowledges. The ring is driven off end_at, not off
//     the server's fire, which arrives seconds later (see isDue).
//   * a timer already past end_at when the app OPENS counts as acknowledged —
//     we silence it instead of blaring (the away case got a push).

import { startAlarm, stopAlarm, alarmRunning, isBuddyMuted } from "./alarm";
import { onChipTap } from "./chip_taps";

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

// The board banner's readout, in the Whisper countdown style: whole minutes
// (rounded UP) for as long as more than a minute is left, then a seconds count
// in the final minute. The point is a wall-tablet reading from across the room
// — "14m" rather than "13:47" ticking too fast to read — dropping to ":45s"
// only when the end is close. Clamped at zero so it never counts negative.
function fmtBanner(ms) {
  const secs = Math.max(0, ms / 1000);
  if (secs > 0 && secs <= 60) return `:${Math.ceil(secs)}s`;
  return `${Math.ceil(secs / 60)}m`;
}

// The progress ring is a 45-radius circle in a 100×100 viewBox, same geometry
// as Whisper's duration rings; the stroke recedes as time elapses.
const BANNER_CIRCUMFERENCE = 2 * Math.PI * 45;

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

// A WAIT is Buddy holding the middle of a sequence — "play the nap sound in 5
// minutes" — rather than a countdown the person set and is watching. The chip
// is the only sign the delay is real, so it shows and it ticks; what it must
// not do is ring, or sit at 0:00 waiting to be dismissed. The server archives
// it the moment the step it was holding runs, so it leaves on its own.
//
// Otherwise the wait behind a sound blares like a kitchen timer and gets
// tapped away seconds later, when nothing was being asked at all — the sound
// was already playing.
function isWait(t) {
  return !!t.wait;
}

// The countdown reaching zero IS the moment — so that's what rings, rather
// than the server's word for it.
//
// Firing is a Sidekiq job scheduled for end_at, and Sidekiq polls its scheduled
// set on an interval (~5s by default), so `fired_at` lands somewhere in the
// several seconds AFTER the alarm was due. Waiting for it put an audible gap
// between asking for an alarm and hearing one - the chip and the fire land
// several seconds apart, and the room is silent for all of it.
//
// end_at is already here — it arrives on the `created` broadcast and the ticker
// below is reading it 4 times a second to paint the readout. Nothing has to be
// fetched or waited for.
function isDue(t) {
  if (isFired(t)) return true;
  if (t.confirmed_at || isPaused(t) || !t.started_at || !t.end_at) return false;
  return Date.parse(t.end_at) <= Date.now();
}

export function initBuddyTimers({ container, hero, isBuddyActiveFn, enabled = true, banner = null }) {
  if (!container) return null;

  // A wall surface (board / kiosk) can turn its timer alerts off, and off means
  // GONE here — no chips, no ring, no face takeover, and the per-user :timers
  // stream ignored — not merely silenced. The chat is always enabled; it is the
  // home of the timers.
  let active = enabled !== false;

  const timers = new Map(); // id → serialized timer
  let pageId = null;
  let tickHandle = 0;
  // The timer the board banner is currently drawn for, so a tick updates its
  // ring and readout in place and only a change of lead rebuilds the markup.
  let bannerId = null;
  let ackArmed = false;
  let ackHandler = null;
  let dueCount = 0;
  // Ids we've stopped ringing for locally, still waiting on the server's fire
  // before they can be confirmed. See drainSilenced.
  const silenced = new Set();
  // Ids with a DELETE in flight, and ids whose DELETE came back failed. See
  // cancelTimer — the × is a REQUEST to cancel, not the cancellation.
  const cancelling = new Set();
  const cancelFailed = new Set();

  const isBuddyActive = () => (isBuddyActiveFn ? isBuddyActiveFn() : true);

  // ---- rendering ----------------------------------------------------------

  function ordered() {
    // Due first (they need attention), then soonest-to-expire.
    return Array.from(timers.values()).sort((a, b) => {
      const fa = isDue(a) ? 0 : 1;
      const fb = isDue(b) ? 0 : 1;
      if (fa !== fb) return fa - fb;
      return remainingMs(a) - remainingMs(b);
    });
  }

  function render() {
    if (!active) {
      container.hidden = true;
      container.innerHTML = "";
      hideBanner();
      return;
    }
    const list = ordered();
    // On a board the lead timer (ringing first, else soonest) is blown up to the
    // banner; the corner chips carry only the rest. Everywhere else the banner
    // is absent and every timer is a chip.
    renderBanner(list);
    const chipList = banner ? list.slice(1) : list;
    container.hidden = chipList.length === 0 || !isBuddyActive();
    container.innerHTML = "";

    chipList.forEach((t) => {
      // A wait that has reached zero is finished, not ringing — it never wears
      // the fired face, and it is about to be archived out from under itself.
      const ringing = isDue(t) && !isWait(t);
      const chip = document.createElement("div");
      chip.className = "byte-timer-chip";
      chip.dataset.timerId = t.id;
      chip.dataset.state = ringing ? "fired" : isPaused(t) ? "paused" : "running";
      // Dimmed and untouchable while the DELETE is out, so the tap reads as
      // "going" rather than "gone"; flashed if the server never took it.
      if (cancelling.has(t.id)) chip.dataset.pending = "cancel";
      if (cancelFailed.has(t.id)) chip.dataset.pending = "cancel-failed";
      if (t.color) chip.style.setProperty("--timer-accent", t.color);

      const icon = document.createElement("span");
      icon.className = "byte-timer-icon";
      icon.textContent = ringing ? "⏰" : isPaused(t) ? "⏸" : "⏲";
      chip.appendChild(icon);

      const readout = document.createElement("span");
      readout.className = "byte-timer-readout";
      readout.dataset.readout = t.id;
      readout.textContent = ringing ? "0:00" : fmt(remainingMs(t));
      chip.appendChild(readout);

      if (t.name) {
        const name = document.createElement("span");
        name.className = "byte-timer-name";
        name.textContent = t.name;
        chip.appendChild(name);
      }

      // A chip mid-cancel takes no taps: a second × would fire a second DELETE,
      // and a tap on the body would pause a timer that is on its way out. A
      // wait that has run out is in the same position — the archive is already
      // on its way — and a tap on one would cancel a timer that has done its
      // job.
      const settled = cancelling.has(t.id) || (isDue(t) && isWait(t));
      if (!settled) {
        chip.appendChild(closeButton(t));
        wireChip(chip, t);
      }
      container.appendChild(chip);
    });

    // Any render guarantees the local ticker is live (idempotent). Belt-and-
    // suspenders so a re-render can never leave a running timer frozen because
    // a prior tick self-cleared the interval.
    ensureTicking();
  }

  // ---- board banner -------------------------------------------------------

  function hideBanner() {
    if (!banner) return;
    banner.hidden = true;
    banner.innerHTML = "";
    banner.style.removeProperty("--timer-accent");
    bannerId = null;
  }

  // The lead timer, drawn big. Rebuilds the markup only when the lead changes;
  // otherwise `updateBanner` moves the ring and readout in place each tick.
  function renderBanner(list) {
    if (!banner) return;
    const lead = isBuddyActive() ? list[0] : null;
    if (!lead) return hideBanner();

    if (bannerId !== lead.id || !banner.firstChild) {
      bannerId = lead.id;
      banner.innerHTML = `
        <div class="byte-board-timer-ring" data-state="running">
          <svg class="byte-board-timer-svg" viewBox="0 0 100 100" aria-hidden="true">
            <circle class="byte-board-timer-track" cx="50" cy="50" r="45"></circle>
            <circle class="byte-board-timer-progress" cx="50" cy="50" r="45"
                    stroke-dasharray="${BANNER_CIRCUMFERENCE.toFixed(2)}"></circle>
          </svg>
          <span class="byte-board-timer-readout" data-banner-readout></span>
        </div>
        <div class="byte-board-timer-label" data-banner-label hidden></div>
      `;
    }
    banner.hidden = false;
    if (lead.color) banner.style.setProperty("--timer-accent", lead.color);
    else banner.style.removeProperty("--timer-accent");
    updateBanner(lead);
  }

  function updateBanner(t) {
    if (!banner || !banner.firstChild) return;
    const ringing = isDue(t) && !isWait(t);
    const remMs = remainingMs(t);
    const totalMs = t.duration_ms || remMs || 1;
    const progress = Math.min(Math.max((totalMs - remMs) / totalMs, 0), 1);

    const ringEl = banner.querySelector(".byte-board-timer-ring");
    const prog = banner.querySelector(".byte-board-timer-progress");
    const readout = banner.querySelector("[data-banner-readout]");
    const label = banner.querySelector("[data-banner-label]");

    if (ringEl) {
      ringEl.dataset.state = ringing ? "fired" : isPaused(t) ? "paused" : "running";
    }
    if (prog) {
      prog.setAttribute("stroke-dashoffset", (BANNER_CIRCUMFERENCE * progress).toFixed(2));
    }
    if (readout) readout.textContent = ringing ? "0m" : fmtBanner(remMs);
    if (label) {
      label.textContent = t.name || "";
      label.hidden = !t.name;
    }
  }

  // Update only the readout text each tick — cheap, no re-layout. A timer
  // crossing its end_at gets the fuller treatment: that changes the chip's
  // state and its place in the stack, and it's the moment the alarm starts.
  function tick() {
    let anyRunning = false;
    let due = 0;
    timers.forEach((t) => {
      if (isPaused(t)) return;
      if (isDue(t)) {
        due += 1;
        return;
      }
      anyRunning = true;
      const el = container.querySelector(`[data-readout="${t.id}"]`);
      if (el) el.textContent = fmt(remainingMs(t));
    });
    // The banner's lead is not in the chip list, so move it here too — its ring
    // and readout have to advance every tick, not only when the stack changes.
    if (banner && bannerId != null) {
      const lead = timers.get(bannerId);
      if (lead) updateBanner(lead);
    }
    if (due !== dueCount) {
      render();
      syncAlarm();
    }
    if (!anyRunning && tickHandle) {
      clearInterval(tickHandle);
      tickHandle = 0;
    }
  }

  function ensureTicking() {
    if (!tickHandle) tickHandle = window.setInterval(tick, 250);
  }

  // ---- interaction: tap = pause/resume, × = cancel ------------------------

  // A real button, so it is reachable by keyboard and reads as a control. The
  // hit area is padding rather than glyph size — see .byte-chip-close.
  function closeButton(t) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "byte-chip-close";
    btn.textContent = "×";
    const label = `Cancel ${t.name || "timer"}`;
    btn.title = label;
    btn.setAttribute("aria-label", label);
    onChipTap(btn, (e) => {
      e.stopPropagation();
      e.preventDefault();
      cancelTimer(t.id);
    });
    return btn;
  }

  function wireChip(chip, t) {
    onChipTap(chip, (e) => {
      // The × is inside the chip, and it has already done its own thing.
      if (e.target?.closest?.("button")) return;

      // A RINGING chip is finished with, so a tap on it ends it. It used to run
      // pause/resume like any other chip, which left the thing paused at zero
      // forever: the alarm stopped (any tap anywhere does that), the countdown
      // had nowhere left to go, and the chip sat in the corner as a ⏸ nobody
      // could do anything with. It is also the tap most likely to be a reflex
      // at a noise, and "make it stop" means gone, not parked.
      //
      // Acknowledging WITHOUT cancelling is still there and is what every other
      // tap does — `armAck` silences on a pointerdown anywhere on the page. It
      // is only a tap on the ringing chip itself that means this one is done.
      const current = timers.get(t.id) || t;
      if (isDue(current)) cancelTimer(current.id);
      else toggleTimer(current);
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

  // A tap on the × is a REQUEST to cancel. It is not the cancellation.
  //
  // This used to delete the timer from the local store and re-render on the
  // spot, then fire the DELETE into a `catch` that only wrote to the console.
  // When the request didn't land there was nothing left to say so: the chip was
  // already gone, the row was still live on the server, and the next hydrate or
  // broadcast put it back — usually unnoticed, because by then nobody is
  // looking at the corner of the screen - a timer dismissed here can vanish
  // and still ring an hour later, with no DELETE reaching Rails at all and
  // every part of the UI saying one had.
  //
  // So the chip stays, visibly pending, until the server agrees. Removal comes
  // from the response or from the `archived` broadcast, both of which are
  // truth; a failure puts the chip back with a flash, because the one thing
  // that must not happen is the person walking away believing it's cancelled.
  async function cancelTimer(id) {
    if (cancelling.has(id)) return;

    cancelFailed.delete(id);
    cancelling.add(id);
    render();
    try {
      await apiCall(`/buddy/timers/${id}`, "DELETE");
      cancelling.delete(id);
      timers.delete(id);
      render();
      syncAlarm();
    } catch (e) {
      console.warn("[buddy] timer cancel failed", e);
      cancelling.delete(id);
      cancelFailed.add(id);
      render();
      // The flash is the whole message — there is no toast in Byte — so it
      // clears itself rather than staying on as permanent decoration.
      window.setTimeout(() => {
        if (!cancelFailed.delete(id)) return;

        render();
      }, 2000);
    }
  }

  // ---- alarm orchestration ------------------------------------------------

  function dueTimers() {
    return Array.from(timers.values()).filter(isDue);
  }

  // The ones that actually make a noise. A wait is due like any other timer and
  // sorts to the top of the stack like any other, but it has nothing to say and
  // nothing to acknowledge — so it stays out of the alarm, out of the ack, and
  // out of the silenced bookkeeping that exists to serve them.
  function ringingTimers() {
    return dueTimers().filter((t) => !isWait(t));
  }

  // Ring while any timer is due; a single tap anywhere acknowledges them all.
  //
  // `dueCount` still counts every due timer, waits included — it is what `tick`
  // compares against to notice the stack changed, and filtering it here would
  // re-render four times a second for as long as a spent wait sat in the list.
  // Only the RINGING set is narrowed.
  function syncAlarm() {
    const due = dueTimers();
    dueCount = due.length;
    const ringing = ringingTimers();

    if (ringing.some((t) => !silenced.has(t.id))) {
      if (!alarmRunning()) startAlarm({ hero });
      armAck();
    } else if (alarmRunning()) {
      stopAlarm({ hero });
      disarmAck();
    }
    drainSilenced();
  }

  // A timer silenced on our clock is confirmed once the SERVER agrees it fired,
  // and not a moment before. `confirm!` clears end_at, and TimerFireWorker
  // bails on a timer with no end_at — so confirming inside the few seconds
  // before the scheduled fire runs would cancel it, and with it the line in the
  // thread and the push that are the record of the alarm going off.
  function drainSilenced() {
    Array.from(silenced).forEach((id) => {
      const t = timers.get(id);
      if (!t) {
        silenced.delete(id);
        return;
      }
      if (!isFired(t)) return;
      silenced.delete(id);
      confirmTimer(id);
    });
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
    ringingTimers().forEach((t) => {
      if (isFired(t)) confirmTimer(t.id);
      else silenced.add(t.id);
    });
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
      if (!active) return;
      try {
        const data = await apiCall("/buddy/timers", "GET");
        pageId = data.page_id;
        timers.clear();
        (data.timers || []).forEach((t) => timers.set(t.id, t));

        // Anything already past its end_at when we load went off while they
        // were away — the push covered it — so it's silenced rather than blared
        // at them on open. One already FIRED can be confirmed outright; one the
        // server hasn't caught up with yet waits, same as a local ack.
        // Anything already past its end_at when we load went off while they
        // were away — the push covered it — so it's silenced rather than blared
        // at them on open. syncAlarm confirms the ones the server has already
        // fired and holds the rest until it catches up.
        ringingTimers().forEach((t) => silenced.add(t.id));
        render();
        ensureTicking();
        syncAlarm();
      } catch (e) {
        console.warn("[buddy] timer hydrate failed", e);
      }
    },

    // A :timers MonitorChannel broadcast. Ignores timers that aren't Buddy's
    // (the person's regular board timers ride the same per-user stream).
    applyBroadcast(payload) {
      if (!active) return;
      const data = payload?.data || {};
      const t = data.timer;
      if (!t) return;
      if (pageId != null && t.timer_page_id !== pageId) return;
      if (data.reason === "archived") {
        // Whoever archived it, the tap that asked for it is answered.
        cancelling.delete(t.id);
        cancelFailed.delete(t.id);
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

    // The surface's "Timer alerts" switch. Turning it off tears everything
    // down at once — the chips, the alarm, the ack listener, the local ticker —
    // and makes the stream a no-op; turning it on re-hydrates from the server.
    setEnabled(on) {
      const next = on !== false;
      if (next === active) return;

      active = next;
      if (!active) {
        timers.clear();
        silenced.clear();
        cancelling.clear();
        cancelFailed.clear();
        if (tickHandle) {
          clearInterval(tickHandle);
          tickHandle = 0;
        }
        stopAlarm({ hero });
        disarmAck();
        dueCount = 0;
        render();
      } else {
        this.hydrate();
      }
    },

    muted: isBuddyMuted,
  };
}
