// Buddy's countdown timer chips — the vertical stack pinned top-left under the
// nav. Server-authoritative: the Timer model fires via Sidekiq and broadcasts,
// so this is purely presentation + reconciliation. It:
//   * hydrates the live list on load / reconnect (GET /buddy/timers)
//   * applies :timers MonitorChannel broadcasts (create/pause/resume/fire/archive)
//   * ticks every 250ms to update the remaining-time readout off end_at
//   * tap a chip → pause/resume, or cancel if it's the one ringing;
//     swipe it away → cancel. Either way the SERVER decides when it goes.
//   * on a timer reaching end_at WHILE open → rings the grub alarm + face loop
//     until a tap anywhere acknowledges. The ring is driven off end_at, not off
//     the server's fire, which arrives seconds later (see isDue).
//   * a timer already past end_at when the app OPENS counts as acknowledged —
//     we silence it instead of blaring (the away case got a push).

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

// A WAIT is Buddy holding the middle of a sequence — "play the nap sound in 5
// minutes" — rather than a countdown the person set and is watching. The chip
// is the only sign the delay is real, so it shows and it ticks; what it must
// not do is ring, or sit at 0:00 waiting to be dismissed. The server archives
// it the moment the step it was holding runs, so it leaves on its own.
//
// Prod timer 98, 4 Sep: the nap-sound wait blared like a kitchen timer and was
// tapped away two seconds later. Nothing was being asked of him — the sound
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
// between asking for an alarm and hearing one: prod 4062 (the chip) and 4063
// (the fire) were 5.6 seconds apart, and the room was silent for all of it.
//
// end_at is already here — it arrives on the `created` broadcast and the ticker
// below is reading it 4 times a second to paint the readout. Nothing has to be
// fetched or waited for.
function isDue(t) {
  if (isFired(t)) return true;
  if (t.confirmed_at || isPaused(t) || !t.started_at || !t.end_at) return false;
  return Date.parse(t.end_at) <= Date.now();
}

export function initBuddyTimers({ container, hero, isBuddyActiveFn }) {
  if (!container) return null;

  const timers = new Map(); // id → serialized timer
  let pageId = null;
  let tickHandle = 0;
  let ackArmed = false;
  let ackHandler = null;
  let dueCount = 0;
  // Ids we've stopped ringing for locally, still waiting on the server's fire
  // before they can be confirmed. See drainSilenced.
  const silenced = new Set();
  // Ids with a DELETE in flight, and ids whose DELETE came back failed. See
  // cancelTimer — a swipe is a REQUEST to cancel, not the cancellation.
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
    const list = ordered();
    container.hidden = list.length === 0 || !isBuddyActive();
    container.innerHTML = "";

    list.forEach((t) => {
      // A wait that has reached zero is finished, not ringing — it never wears
      // the fired face, and it is about to be archived out from under itself.
      const ringing = isDue(t) && !isWait(t);
      const chip = document.createElement("div");
      chip.className = "byte-timer-chip";
      chip.dataset.timerId = t.id;
      chip.dataset.state = ringing ? "fired" : isPaused(t) ? "paused" : "running";
      // Dimmed and untouchable while the DELETE is out, so a swipe reads as
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

      // A chip mid-cancel takes no gestures: a second swipe would fire a second
      // DELETE, and a tap would pause a timer that is on its way out. A wait
      // that has run out is in the same position — the archive is already on
      // its way — and a tap on one would cancel a timer that has done its job.
      if (!cancelling.has(t.id) && !(isDue(t) && isWait(t))) wireChip(chip, t);
      container.appendChild(chip);
    });

    // Any render guarantees the local ticker is live (idempotent). Belt-and-
    // suspenders so a re-render can never leave a running timer frozen because
    // a prior tick self-cleared the interval.
    ensureTicking();
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

  // ---- interaction: tap = pause/resume, swipe = cancel --------------------

  function wireChip(chip, t) {
    let startX = null;
    let dragging = false;

    const release = (e) => {
      try {
        if (chip.hasPointerCapture(e.pointerId)) chip.releasePointerCapture(e.pointerId);
      } catch (_) { /* already gone */ }
    };

    // Capture the pointer, or the swipe strands the chip.
    //
    // Dragging works by translating the chip out from under the finger. Without
    // capture the browser retargets every following pointer event to whatever
    // is under the finger NOW, which is no longer the chip - so pointermove
    // stops arriving, pointerup never fires, `finish` never runs, and the chip
    // is left sitting at its last transform with the timer still very much
    // alive. Swiped either way, it stayed where it was put and never went away.
    chip.addEventListener("pointerdown", (e) => {
      startX = e.clientX;
      dragging = false;
      try { chip.setPointerCapture(e.pointerId); } catch (_) { /* no capture, no drag */ }
    });
    chip.addEventListener("pointermove", (e) => {
      if (startX == null) return;
      const dx = e.clientX - startX;
      if (Math.abs(dx) > 6) dragging = true;
      if (dragging) chip.style.transform = `translateX(${dx}px)`;
      chip.style.opacity = String(Math.max(0.2, 1 - Math.abs(dx) / 160));
    });
    const finish = (e) => {
      release(e);
      if (startX == null) return;
      const dx = e.clientX - startX;
      startX = null;
      if (dragging && Math.abs(dx) > 90) {
        // Deliberately NOT flung off-screen here. That was truth applied to a
        // gesture: the chip left the corner, the request was still in the air,
        // and a chip that vanished on a failed DELETE is exactly how a live
        // timer ends up believed cancelled. `cancelTimer` re-renders it pending
        // on the spot and removes it when the server says so.
        chip.style.transform = "";
        chip.style.opacity = "";
        cancelTimer(t.id);
        return;
      }
      chip.style.transform = "";
      chip.style.opacity = "";
      if (dragging) return;

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
    };
    chip.addEventListener("pointerup", finish);
    chip.addEventListener("pointercancel", (e) => {
      release(e);
      startX = null;
      dragging = false;
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

  // A swipe is a REQUEST to cancel. It is not the cancellation.
  //
  // This used to delete the timer from the local store and re-render on the
  // spot, then fire the DELETE into a `catch` that only wrote to the console.
  // When the request didn't land there was nothing left to say so: the chip was
  // already gone, the row was still live on the server, and the next hydrate or
  // broadcast put it back — usually unnoticed, because by then nobody is
  // looking at the corner of the screen. Prod timer 94, 27 Aug: swiped away,
  // vanished, and rang an hour later anyway. `log_trackers` has no DELETE for
  // it at all until the second swipe four minutes AFTER it went off, so the
  // first request never reached Rails, and every part of the UI said it had.
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
      const data = payload?.data || {};
      const t = data.timer;
      if (!t) return;
      if (pageId != null && t.timer_page_id !== pageId) return;
      if (data.reason === "archived") {
        // Whoever archived it, the swipe that asked for it is answered.
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

    muted: isBuddyMuted,
  };
}
