// Per-kind timer-card renderers. Each returns `{ node, update(timer) }`.
// Update() runs both on every store change AND at the IntervalTicker
// cadence (~250ms) so live countdowns repaint locally. It NEVER calls
// the network — all timing math is derived from server-stamped fields
// (started_at, end_at, paused_*) plus Date.now().

import { autoColor } from "./colors";
import { formatRingTime, formatDurationShort, formatElapsedTime } from "./duration";
import { startTimerSound, stopTimerSound } from "./audio";
import { isMuted } from "./header";

const RING_R = 45;
const RING_CIRC = 2 * Math.PI * RING_R;
const COUNTER_R = 42;
const COUNTER_CIRC = 2 * Math.PI * COUNTER_R;

function makeCardFrame(timer, actions) {
  const card = document.createElement("article");
  card.className = `timer-card timer-card-${timer.kind}`;
  card.dataset.timerId = timer.id;
  card.style.setProperty("--ring-color", autoColor(timer));

  // Top-left "delete when done" X button. Always rendered; CSS shows it
  // only when the card is both `.on-home` (mounted by the home view, not
  // a custom page) AND `.is-done`. Custom pages preserve their layout.
  const close = document.createElement("button");
  close.type = "button";
  close.className = "timer-card-close";
  close.dataset.timerClose = "1";
  close.setAttribute("aria-label", "Delete timer");
  close.innerHTML = "&times;";
  close.addEventListener("click", (e) => {
    e.stopPropagation();
    if (!actions?.destroy) return;
    const inEditMode = card.closest(".timers-app")?.classList.contains("edit-mode");
    if (!inEditMode && !window.confirm("Delete this timer?")) return;
    actions.destroy(timer.id);
  });
  card.appendChild(close);

  const menu = document.createElement("button");
  menu.type = "button";
  menu.className = "timer-card-menu";
  menu.dataset.timerMenu = "1";
  menu.setAttribute("aria-label", "Timer options");
  menu.innerHTML = "&#8942;";
  card.appendChild(menu);

  return card;
}

function applyState(card, timer, { clientFired } = {}) {
  const fired = !!(clientFired || (timer.fired_at && !timer.confirmed_at));
  const paused = !!timer.paused_at;
  // Repeating timers auto-restart server-side; we never want the
  // persistent red "needs confirm" pulse for them. The .is-flash one-
  // shot animation (driven by repeat_count change in update()) is the
  // entire visual feedback for a repeat fire.
  card.classList.toggle("is-done", fired && !timer.repeat);
  card.classList.toggle("is-paused", paused);
  card.classList.toggle("is-disabled", !!timer.disabled);
  // Color edits ride the same broadcast/upsert path as every other
  // attribute change. `--ring-color` was originally set once in
  // makeCardFrame, so the ring stayed on the old color until the
  // page was reloaded — re-applying here keeps it in sync on every
  // store-driven repaint (edits, broadcasts, sync).
  card.style.setProperty("--ring-color", autoColor(timer));
}

// Local time math — uses server-authoritative start/end stamps. No
// network calls, no setInterval triggered server hits.
export function computeRemaining(t) {
  if (t.kind !== "countdown") return 0;
  if (t.fired_at && !t.confirmed_at) return 0;
  if (t.paused_at) return t.paused_remaining_ms || 0;
  if (!t.started_at) return t.duration_ms || 0;
  if (!t.end_at) return t.duration_ms || 0;
  const endMs = Date.parse(t.end_at);
  if (Number.isNaN(endMs)) return t.duration_ms || 0;
  return Math.max(0, endMs - Date.now());
}

function elapsedSinceFire(t) {
  if (t.kind !== "countdown") return 0;
  if (t.fired_at) return Math.max(0, Date.now() - Date.parse(t.fired_at));
  if (!t.end_at) return 0;
  return Math.max(0, Date.now() - Date.parse(t.end_at));
}

// Accepts callbacks in BOTH the new shape (`{when:{type}, then:{type}}`)
// and the legacy flat shape (`{event, type, ...}`). Picks the first
// :complete-trigger sound row — the one that plays when the countdown
// itself finishes.
function soundCallback(t) {
  return (t.callbacks || []).find((cb) => {
    const w = cb.when?.type || cb.event || "complete";
    const a = cb.then?.type || cb.type;
    return a === "sound" && w === "complete";
  });
}

function soundActionOf(cb) {
  return cb.then || cb;
}

// Mid-countdown sound triggers — `when.type == "countdown_at"` AND
// `then.type == "sound"`. The ticker watches each running countdown
// and fires the chime locally when the remaining time crosses the
// configured threshold. Server-side these stay UNscheduled (sound is
// always client-only); push/jil/chain mid-countdown triggers fire
// from TimerCallbackWorker independently.
function countdownAtSoundCallbacks(t) {
  return (t.callbacks || []).filter(
    (cb) => cb.when?.type === "countdown_at" && cb.then?.type === "sound",
  );
}

// =========================
// Countdown
// =========================

export function renderCountdownCard(timer, actions) {
  const card = makeCardFrame(timer, actions);

  const ring = document.createElement("div");
  ring.className = "timer-ring";
  ring.innerHTML = `
    <svg viewBox="0 0 100 100" aria-hidden="true">
      <circle class="ring-bg"       cx="50" cy="50" r="${RING_R}"></circle>
      <circle class="ring-progress" cx="50" cy="50" r="${RING_R}"
              stroke-dasharray="${RING_CIRC}" stroke-dashoffset="0"
              transform="rotate(-90 50 50)"></circle>
    </svg>
    <div class="ring-label"></div>
    <div class="ring-sublabel"></div>
  `;
  card.appendChild(ring);

  const name = document.createElement("div");
  name.className = "timer-card-name";
  card.appendChild(name);

  const progressEl = ring.querySelector(".ring-progress");
  const labelEl    = ring.querySelector(".ring-label");
  const subEl      = ring.querySelector(".ring-sublabel");

  let wasFired = (() => {
    if (timer.fired_at && !timer.confirmed_at) return true;
    const r = computeRemaining(timer);
    return !!(timer.started_at && !timer.paused_at && r <= 0);
  })();

  // Re-arm a REPEATING sound on page load / re-visit if the timer is
  // sitting in the fired-but-unconfirmed state. A "once" cadence is
  // not re-armed — it'd be jarring to play a chime the moment you
  // navigate back to a fired timer you already half-acknowledged by
  // closing the tab. Repeating cadences DO restart because their whole
  // job is to keep nagging until confirmed.
  if (wasFired) {
    const cb = soundCallback(timer);
    const a  = cb && soundActionOf(cb);
    if (a && a.cadence && a.cadence !== "once" && !isMuted()) {
      startTimerSound(timer.id, { chime: a.chime || "soft", cadence: a.cadence });
    }
  }

  // Per-callback threshold-crossing memo for countdown_at sound triggers.
  // We fire a callback's chime the first time `remaining_ms` falls below
  // its configured value within a single run; cleared on restart/reset
  // so the next run rearms cleanly.
  const firedCountdownAt = new Set();

  // Repeat lifecycle: when a repeating timer transitions from running
  // to fired (either via local-tick detection or an incoming :fired
  // broadcast), we flash the card AND POST /start to restart it. The
  // flag guards against re-firing the restart on every subsequent tick
  // — it clears once the broadcast comes back with fresh started_at.
  let flashTimer = null;
  let repeatRestartRequested = false;

  card.addEventListener("click", (e) => {
    if (e.target.closest("[data-timer-menu]")) return;
    if (e.target.closest(".timers-card-menu-popup")) return;
    if (card.closest(".timers-app")?.classList.contains("edit-mode")) return;
    if (timer.disabled) return;
    stopTimerSound(timer.id); // only this card's sound

    const remaining = computeRemaining(timer);
    const clientFired = !!(timer.started_at && !timer.paused_at && remaining <= 0 && !timer.fired_at);
    const fired = clientFired || (timer.fired_at && !timer.confirmed_at);

    if (fired && !timer.repeat) {
      // Non-repeating fired countdowns require an explicit tap to
      // confirm — confirm() resets them back to neutral, ready to
      // start again. Repeating timers auto-restart server-side; a tap
      // in the brief gap before the broadcast arrives falls through to
      // the normal pause/resume/start handling below.
      actions.confirm(timer.id);
      return;
    }
    if (timer.started_at && !timer.paused_at) actions.pause(timer.id);
    else if (timer.paused_at) actions.resume(timer.id);
    else actions.start(timer.id);
  });

  function update(t) {
    timer = t;
    const remaining = computeRemaining(t);
    const clientFired = !!(t.started_at && !t.paused_at && remaining <= 0 && !t.fired_at);
    const fired = clientFired || (t.fired_at && !t.confirmed_at);

    applyState(card, t, { clientFired });
    name.textContent = t.name || formatDurationShort((t.duration_ms || 0) / 1000);

    const total = t.duration_ms || 1;
    const progress = Math.max(0, Math.min(1, 1 - remaining / total));
    progressEl.setAttribute("stroke-dashoffset", String(RING_CIRC * progress));

    if (fired && !t.repeat) {
      // Count UP from the moment the timer expired so the user can see
      // how long ago it went off. Tap dismisses.
      labelEl.textContent = formatElapsedTime(elapsedSinceFire(t));
      subEl.textContent = "tap to confirm";
    } else if (fired && t.repeat) {
      // Brief gap between the client detecting a fire and the server's
      // :repeated broadcast arriving with the new started_at/end_at.
      // Show full duration so the ring snaps cleanly into the next
      // run rather than freezing at "tap to confirm".
      labelEl.textContent = formatRingTime(t.duration_ms || 0);
      subEl.textContent = "↻ repeating";
    } else if (t.paused_at) {
      labelEl.textContent = formatRingTime(t.paused_remaining_ms || 0);
      subEl.textContent = "▶ tap to resume";
    } else if (t.started_at) {
      labelEl.textContent = formatRingTime(remaining);
      subEl.textContent = "tap to pause";
    } else {
      labelEl.textContent = formatRingTime(t.duration_ms || 0);
      subEl.textContent = "▶ tap to start";
    }

    if (fired && !wasFired) {
      const cb = soundCallback(t);
      const a  = cb && soundActionOf(cb);
      if (a && !isMuted()) {
        startTimerSound(t.id, { chime: a.chime || "soft", cadence: a.cadence || "once" });
      }
    }
    if (!fired && wasFired) stopTimerSound(t.id);

    // Reset the threshold-crossing memo on every fresh start so the next
    // run plays the chime again. We treat any non-running state as
    // "between runs": pause-resume preserves the set; start-from-zero
    // and reset wipe it.
    if (!t.started_at && !t.paused_at) firedCountdownAt.clear();

    // Detect threshold crossings for countdown_at sound triggers. We
    // play the chime once per (callback × run); the Set guards against
    // re-firing on every subsequent tick.
    if (t.started_at && !t.paused_at && !fired && !isMuted()) {
      countdownAtSoundCallbacks(t).forEach((cb) => {
        const threshold = cb.when?.remaining_ms;
        if (!threshold || threshold <= 0) return;
        if (remaining > threshold) return;
        if (firedCountdownAt.has(cb.id)) return;
        firedCountdownAt.add(cb.id);
        startTimerSound(`${t.id}:${cb.id}`, {
          chime:   cb.then?.chime   || "soft",
          cadence: cb.then?.cadence || "once",
        });
      });
    }

    // Repeat lifecycle: on the !fired→fired transition for a repeating
    // timer, flash the card and POST /start. The server-side worker
    // has already fired the :complete callbacks (push/jil/chain); this
    // restart just resets the lifecycle so the cycle continues.
    if (fired && t.repeat && !repeatRestartRequested) {
      repeatRestartRequested = true;
      card.classList.remove("is-flash");
      void card.offsetWidth; // restart the keyframe if mid-flight
      card.classList.add("is-flash");
      clearTimeout(flashTimer);
      flashTimer = setTimeout(() => card.classList.remove("is-flash"), 700);
      actions.start(t.id);
    }
    if (!fired) repeatRestartRequested = false;

    wasFired = fired;
  }

  update(timer);
  return {
    node:    card,
    update,
    timer:   () => timer,
    dispose: () => {
      stopTimerSound(timer.id);
      clearTimeout(flashTimer);
    },
  };
}

// =========================
// Counter — vertical layout: ring above, ± buttons below.
// =========================

export function renderCounterCard(timer, actions) {
  const card = makeCardFrame(timer, actions);

  const body = document.createElement("div");
  body.className = "timer-counter";
  body.innerHTML = `
    <div class="timer-counter-display">
      <svg class="counter-ring" viewBox="0 0 100 100" aria-hidden="true">
        <circle class="ring-bg"       cx="50" cy="50" r="${COUNTER_R}"></circle>
        <circle class="ring-progress" cx="50" cy="50" r="${COUNTER_R}"
                stroke-dasharray="${COUNTER_CIRC}" stroke-dashoffset="${COUNTER_CIRC}"
                transform="rotate(-90 50 50)"></circle>
      </svg>
      <div class="timer-counter-value">0</div>
    </div>
    <div class="timer-counter-controls">
      <button type="button" class="timer-counter-btn" data-counter-op="dec" aria-label="Decrement">&minus;</button>
      <button type="button" class="timer-counter-btn" data-counter-op="inc" aria-label="Increment">+</button>
    </div>
    <div class="timer-counter-bounds"></div>
  `;
  card.appendChild(body);

  const name = document.createElement("div");
  name.className = "timer-card-name";
  card.appendChild(name);

  const valueEl  = body.querySelector(".timer-counter-value");
  const boundsEl = body.querySelector(".timer-counter-bounds");
  const decBtn   = body.querySelector('[data-counter-op="dec"]');
  const incBtn   = body.querySelector('[data-counter-op="inc"]');
  const ringSvg  = body.querySelector(".counter-ring");
  const progress = body.querySelector(".counter-ring .ring-progress");

  function bump(by) {
    if (timer.disabled) return;
    stopTimerSound(timer.id);
    actions.increment(timer.id, by);
  }
  decBtn.addEventListener("click", () => bump(-timer.step));
  incBtn.addEventListener("click", () => bump(timer.step));

  function update(t) {
    timer = t;
    applyState(card, t);
    name.textContent = t.name || "Counter";
    valueEl.textContent = String(t.value);

    const min = t.min_value;
    const max = t.max_value;
    const bounded = min != null && max != null && max > min;
    ringSvg.style.opacity = bounded ? "1" : "0";
    if (bounded) {
      const pct = Math.max(0, Math.min(1, (t.value - min) / (max - min)));
      progress.setAttribute("stroke-dashoffset", String(COUNTER_CIRC * (1 - pct)));
    }

    const bits = [];
    if (min != null) bits.push(`min ${min}`);
    if (max != null) bits.push(`max ${max}`);
    if (t.step !== 1) bits.push(`step ${t.step}`);
    boundsEl.textContent = bits.join(" · ");
  }

  update(timer);
  return { node: card, update, timer: () => timer, dispose: () => stopTimerSound(timer.id) };
}

// =========================
// Dial
// =========================

const TAU = Math.PI * 2;
const SVG_NS = "http://www.w3.org/2000/svg";

function polar(cx, cy, r, a) { return { x: cx + r * Math.cos(a), y: cy + r * Math.sin(a) }; }

function slicePath(cx, cy, r0, r1, a0, a1) {
  const p0 = polar(cx, cy, r1, a0);
  const p1 = polar(cx, cy, r1, a1);
  const p2 = polar(cx, cy, r0, a1);
  const p3 = polar(cx, cy, r0, a0);
  const large = a1 - a0 > Math.PI ? 1 : 0;
  return [
    `M ${p0.x} ${p0.y}`,
    `A ${r1} ${r1} 0 ${large} 1 ${p1.x} ${p1.y}`,
    `L ${p2.x} ${p2.y}`,
    `A ${r0} ${r0} 0 ${large} 0 ${p3.x} ${p3.y}`,
    "Z",
  ].join(" ");
}

// Subs can be either bare strings or {name, color} objects. This helper
// normalizes either shape to a string name for label rendering.
function subName(s) {
  if (s == null) return "";
  return typeof s === "string" ? s : String(s.name || "");
}

function subColor(s) {
  return typeof s === "object" && s ? (s.color || null) : null;
}

function dialSteps(cfg) {
  const out = [];
  (cfg?.sections || []).forEach((sec, i) => {
    if (sec.subs && sec.subs.length > 0) {
      sec.subs.forEach((s, j) => out.push({ secIndex: i, subIndex: j, name: subName(s) }));
    } else {
      out.push({ secIndex: i, subIndex: null, name: sec.name });
    }
  });
  return out;
}

export function renderDialCard(timer, actions) {
  const card = makeCardFrame(timer, actions);

  const wrap = document.createElement("div");
  wrap.className = "timer-dial";
  const svg = document.createElementNS(SVG_NS, "svg");
  // Margin between R_OUT and viewBox edge so labels positioned at
  // (R_OUT + R_MID)/2 are NEVER closer than ~40 viewBox units to the
  // edge — that's the headroom that keeps "Enemy" / "Actions" from
  // touching the card border on dense rotations.
  svg.setAttribute("viewBox", "-320 -320 640 640");
  wrap.appendChild(svg);
  card.appendChild(wrap);

  const name = document.createElement("div");
  name.className = "timer-card-name";
  card.appendChild(name);

  const R_OUT = 270, R_MID = 175, R_IN = 80;
  const initialConfigKey = JSON.stringify(timer.dial_config || {});
  const cfg = timer.dial_config || {};
  const sections = cfg.sections || [];
  if (sections.length === 0) {
    const txt = document.createElementNS(SVG_NS, "text");
    txt.setAttribute("class", "dial-label");
    txt.setAttribute("text-anchor", "middle");
    txt.setAttribute("dominant-baseline", "middle");
    txt.setAttribute("font-size", "36");
    txt.textContent = "Edit to add sections";
    svg.appendChild(txt);
  } else {
    // start_offset is a percent of full revolution (0–100). Rotates ALL
    // wedge angles AND the points where labels are placed, so each label
    // tracks its own cell. Label TEXT is never rotated (no transform);
    // it reads horizontally regardless of where on the circle it sits.
    const offsetPct = Number(cfg.start_offset);
    const offsetRad = (Number.isFinite(offsetPct) ? offsetPct : 0) / 100 * TAU;
    const startOffset = -Math.PI / 2 + offsetRad;

    // Weighted section angles — sections can specify `weight: N` to
    // claim N times the arc of a weight-1 section. Default weight is 1.
    // Pre-compute {a0, a1, angle} for each section so subsequent passes
    // (paths, labels, sub layout) all share the same geometry.
    const weights = sections.map((s) => {
      const w = Number(s.weight);
      return Number.isFinite(w) && w > 0 ? w : 1;
    });
    const totalWeight = weights.reduce((s, w) => s + w, 0);
    let cum = startOffset;
    const sectionRanges = weights.map((w) => {
      const angle = (w / totalWeight) * TAU;
      const a0 = cum;
      cum = a0 + angle;
      return { a0, a1: cum, angle };
    });

    // Label sizing keys off the SMALLEST section so a tiny wedge's
    // label still fits — all sections use the same font for visual
    // consistency. Sub-label size is computed per-section since each
    // section's sub count + its own angle determines the fit there.
    const longestSecName = sections.reduce((m, s) => Math.max(m, (s.name || "").length), 4);
    const labelR = (R_OUT + R_MID) / 2;
    const minSectionAngle = Math.min(...sectionRanges.map((r) => r.angle));
    const widthBudgetPerChar = (minSectionAngle * labelR) / Math.max(longestSecName, 1) / 0.6;
    const labelSize = clamp(Math.min(widthBudgetPerChar, 140 / Math.sqrt(sections.length)), 16, 36);

    // ----- 1. Single outer boundary ring -----
    const ring = document.createElementNS(SVG_NS, "circle");
    ring.setAttribute("class", "dial-ring");
    ring.setAttribute("r", String(R_OUT));
    ring.setAttribute("cx", "0");
    ring.setAttribute("cy", "0");
    svg.appendChild(ring);

    // Small radial gap (in radians) inset on EACH side of every wedge.
    // Background shows through, producing clean visual slices between
    // adjacent sections and adjacent subs. ~0.7° per side ≈ ~1.4°
    // total gap between neighbors at typical dial sizes.
    const GAP = 0.012;

    // ----- 2. Section wedge fills -----
    // sec.color (a #hex) feeds the `--section-color` CSS custom
    // property on the path. CSS resolves `.dial-section { fill: var(...) }`
    // to that color. The `.dial-section.current` rule still wins via
    // higher class-specificity to draw the highlight when this is the
    // active step. SVG presentation attributes (`fill="..."`) lose to
    // any CSS selector with non-zero specificity, which is why we use
    // the custom property here rather than the bare attribute.
    sectionRanges.forEach(({ a0, a1 }, i) => {
      const sec = sections[i];
      const p = document.createElementNS(SVG_NS, "path");
      p.setAttribute("class", "dial-section");
      p.setAttribute("d", slicePath(0, 0, R_MID, R_OUT, a0 + GAP, a1 - GAP));
      if (sec.color) p.style.setProperty("--section-color", sec.color);
      p.dataset.kind = "sec";
      p.dataset.secIndex = String(i);
      svg.appendChild(p);
    });

    // ----- 3. Sub wedge fills -----
    sections.forEach((sec, i) => {
      const subs = sec.subs || [];
      if (subs.length === 0) return;
      const { a0, angle } = sectionRanges[i];
      const subAngle = angle / subs.length;
      subs.forEach((sub, j) => {
        const sa0 = a0 + j * subAngle;
        const sa1 = sa0 + subAngle;
        const sp = document.createElementNS(SVG_NS, "path");
        sp.setAttribute("class", "dial-sub");
        sp.setAttribute("d", slicePath(0, 0, R_IN, R_MID, sa0 + GAP, sa1 - GAP));
        const color = subColor(sub);
        if (color) sp.style.setProperty("--section-color", color);
        sp.dataset.kind = "sub";
        sp.dataset.secIndex = String(i);
        sp.dataset.subIndex = String(j);
        svg.appendChild(sp);
      });
    });

    // ----- 4. Labels last (drawn ON TOP of all fills) -----
    sections.forEach((sec, i) => {
      const { a0, a1, angle } = sectionRanges[i];
      const mid = (a0 + a1) / 2;
      const pos = polar(0, 0, labelR, mid);
      const txt = document.createElementNS(SVG_NS, "text");
      txt.setAttribute("class", "dial-label");
      txt.setAttribute("x", String(pos.x));
      txt.setAttribute("y", String(pos.y));
      txt.setAttribute("text-anchor", "middle");
      txt.setAttribute("dominant-baseline", "middle");
      txt.setAttribute("font-size", String(labelSize));
      txt.dataset.secIndex = String(i);
      txt.textContent = sec.name || `${i + 1}`;
      svg.appendChild(txt);

      const subs = sec.subs || [];
      if (subs.length === 0) return;
      const subAngle = angle / subs.length;
      const arcAtSubLabel = subAngle * (R_MID + R_IN) / 2;
      const longestSubName = subs.reduce((m, s) => Math.max(m, subName(s).length), 3);
      const subWidthPerChar = arcAtSubLabel / Math.max(longestSubName, 1) / 0.6;
      // Floor bumped from 10 → 14: at 10 the sub names were unreadable
      // on a phone-width dial. Ceiling raised too so the simpler dials
      // (few subs, lots of room) get the benefit.
      const subLabelSize = clamp(Math.min(subWidthPerChar, 100 / Math.sqrt(subs.length)), 14, 26);

      subs.forEach((sub, j) => {
        const sa0 = a0 + j * subAngle;
        const sa1 = sa0 + subAngle;
        const smid = (sa0 + sa1) / 2;
        const spos = polar(0, 0, (R_MID + R_IN) / 2, smid);
        const st = document.createElementNS(SVG_NS, "text");
        st.setAttribute("class", "dial-sublabel");
        st.setAttribute("x", String(spos.x));
        st.setAttribute("y", String(spos.y));
        st.setAttribute("text-anchor", "middle");
        st.setAttribute("dominant-baseline", "middle");
        st.setAttribute("font-size", String(subLabelSize));
        st.dataset.secIndex = String(i);
        st.dataset.subIndex = String(j);
        st.textContent = subName(sub);
        svg.appendChild(st);
      });
    });
  }

  // Tap = +1, long-press = -1.
  let longTimer = null;
  let firedLongPress = false;
  svg.addEventListener("pointerdown", (e) => {
    if (e.target.closest("[data-timer-menu]")) return;
    if (card.closest(".timers-app")?.classList.contains("edit-mode")) return;
    if (timer.disabled) return;
    firedLongPress = false;
    clearTimeout(longTimer);
    longTimer = setTimeout(() => {
      firedLongPress = true;
      stopTimerSound(timer.id);
      actions.advance(timer.id, -1);
    }, 350);
  });
  svg.addEventListener("pointerup", (e) => {
    clearTimeout(longTimer);
    if (e.target.closest("[data-timer-menu]")) return;
    if (card.closest(".timers-app")?.classList.contains("edit-mode")) return;
    if (timer.disabled) return;
    if (firedLongPress) { firedLongPress = false; return; }
    stopTimerSound(timer.id);
    actions.advance(timer.id, 1);
  });
  svg.addEventListener("pointercancel", () => { clearTimeout(longTimer); firedLongPress = false; });
  svg.addEventListener("pointerleave", () => { clearTimeout(longTimer); });

  function update(t) {
    timer = t;
    if (JSON.stringify(t.dial_config || {}) !== initialConfigKey) return false;

    applyState(card, t);
    name.textContent = t.name || "Dial";
    const steps = dialSteps(t.dial_config);
    if (steps.length === 0) return;
    const idx = ((t.dial_step_index % steps.length) + steps.length) % steps.length;
    const current = steps[idx];
    svg.querySelectorAll(".dial-section,.dial-sub,.dial-sublabel").forEach((el) => el.classList.remove("current"));
    if (!current) return;
    const secEl = svg.querySelector(`[data-kind="sec"][data-sec-index="${current.secIndex}"]`);
    secEl?.classList.add("current");
    if (current.subIndex !== null) {
      const subEl = svg.querySelector(`[data-kind="sub"][data-sec-index="${current.secIndex}"][data-sub-index="${current.subIndex}"]`);
      subEl?.classList.add("current");
      const subLabel = svg.querySelector(`.dial-sublabel[data-sec-index="${current.secIndex}"][data-sub-index="${current.subIndex}"]`);
      subLabel?.classList.add("current");
    }
    return true;
  }

  update(timer);
  return { node: card, update, timer: () => timer, dispose: () => stopTimerSound(timer.id) };
}

function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)); }

// =========================
// Dispatcher
// =========================

export function renderTimerCard(timer, actions) {
  switch (timer.kind) {
    case "countdown": return renderCountdownCard(timer, actions);
    case "counter":   return renderCounterCard(timer, actions);
    case "dial":      return renderDialCard(timer, actions);
    default:          return renderCountdownCard(timer, actions);
  }
}
