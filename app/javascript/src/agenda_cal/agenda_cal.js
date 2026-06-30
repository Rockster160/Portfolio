// Mac-style Calendar PWA — month + week views.
//
// Lives at /agenda/cal (separate webmanifest, scope `/agenda/cal`). The
// default route lands on the week view.
//
// Shared concerns (filter UI, modals, Monitor subscription, edit/details
// flow) come from src/agenda/agenda.js because these pages declare the
// `.agenda-page` class. This file layers on top:
//
//   Month view:
//     - Double-click cell → add modal pre-filled for that day
//     - Click + drag across cells → multi-day all-day event
//     - All-day events render as horizontal BANNERS on each week-row,
//       spanning the columns they cover; multi-day spans break at the
//       Sat→Sun row boundary, with rounded-corner-off hint on the
//       continuation edges
//
//   Week view:
//     - Hour axis runs 3am→3am (matches User#perceived_today rollover)
//     - Timed events split into one block per logical day so an event
//       crossing midnight reads as two blocks butted up against the
//       day boundary
//     - Lane-packed side-by-side layout for overlapping events
//     - Red current-time line on the logical today's column
//     - Double-click empty slot → 1h event with 15-min snap
//     - Click + drag a vertical range → custom-duration event, 15-min snap
//     - All-day events render in the band above the time grid, spanning
//       multi-day ranges as horizontal bars
//
//   Both views:
//     - Monitor broadcasts trigger an HTML refetch that swaps the grid
//       contents in place. No reload, no `setInterval` data poll. Refresh
//       defers while the user is in a modal or focused on an input, and
//       fires the deferred refresh as soon as they leave it.
//     - A setTimeout watches for the next 3am rollover; on fire, refreshes
//       in place (or navigates away if the visible date range no longer
//       contains today).
//
//   Listener safety:
//     - Drag state is module-scope (not per-init), so calling init() again
//       after an HTML swap doesn't accumulate document mousemove/mouseup
//       handlers. Document-level handlers are installed exactly once.

(function () {
  // ---------- helpers ----------
  function $(sel, root) { return (root || document).querySelector(sel); }
  function $$(sel, root) { return Array.from((root || document).querySelectorAll(sel)); }
  function pad(n) { return String(n).padStart(2, "0"); }
  function formatDateISO(d) {
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }
  function formatTimeHHMM(min) {
    const h = Math.floor(min / 60) % 24;
    const m = Math.round(min % 60);
    return `${pad(h)}:${pad(m)}`;
  }
  function formatLabelTime(min) {
    let h = Math.floor(min / 60) % 24;
    const m = Math.round(min % 60);
    const ampm = h >= 12 ? "pm" : "am";
    h = h % 12 || 12;
    return m === 0 ? `${h}${ampm}` : `${h}:${pad(m)}${ampm}`;
  }
  // Compact local-tz time from an epoch — matches fmtCalTime in agenda.js
  // (`9a`, `4:15p`) so the "Leave at" prefix reads the same across views.
  function fmtCalTime(epoch) {
    const d = new Date(Number(epoch) * 1000);
    let h = d.getHours();
    const m = d.getMinutes();
    const suffix = h >= 12 ? "p" : "a";
    h = h % 12 || 12;
    return m === 0 ? `${h}${suffix}` : `${h}:${pad(m)}${suffix}`;
  }
  // Parse a JSON `data-*-legs` attribute string off seed.dataset. Tolerates
  // empty/missing strings (recurring schedules without a multi-stop chain
  // carry "") and malformed JSON (returns null — render falls back to the
  // single-band visual).
  function parseLegsAttr(raw) {
    if (!raw) return null;
    try {
      const parsed = JSON.parse(raw);
      return Array.isArray(parsed) ? parsed : null;
    } catch (_err) {
      return null;
    }
  }

  // Append per-leg subdivisions inside a travel band. Each drive leg renders
  // as a stripe segment with alternating angle (135deg / 45deg by index); each
  // dwell renders as a solid contrast bar with thickness ∝ the dwell duration.
  // Heights are proportional to leg seconds vs the total band seconds, so the
  // sum exactly fills the band regardless of pxPerMin rounding.
  function appendLegBars(band, legs, totalSeconds, bandPx) {
    if (!legs || !legs.length || !totalSeconds || !bandPx) return;

    const totalIncludingDwell = legs.reduce((acc, leg) => (
      acc + (Number(leg.drive_seconds) || 0) + (Number(leg.dwell_seconds) || 0)
    ), 0);
    if (totalIncludingDwell <= 0) return;

    legs.forEach((leg, idx) => {
      const driveSecs = Number(leg.drive_seconds) || 0;
      const dwellSecs = Number(leg.dwell_seconds) || 0;
      if (driveSecs > 0) {
        const drive = document.createElement("div");
        drive.className = "cal-week-event-travel-leg cal-week-event-travel-leg-drive";
        drive.dataset.legIndex = String(idx);
        if (idx % 2 === 1) drive.classList.add("is-alt");
        drive.style.height = `${(driveSecs / totalIncludingDwell) * bandPx}px`;
        band.appendChild(drive);
      }
      if (dwellSecs > 0) {
        const dwell = document.createElement("div");
        dwell.className = "cal-week-event-travel-leg cal-week-event-travel-leg-dwell";
        dwell.dataset.dwellSeconds = String(dwellSecs);
        dwell.style.height = `${(dwellSecs / totalIncludingDwell) * bandPx}px`;
        band.appendChild(dwell);
      }
    });
  }

  function compareISO(a, b) { return a < b ? -1 : (a > b ? 1 : 0); }
  function addDaysISO(iso, n) {
    const d = new Date(iso + "T12:00:00");
    d.setDate(d.getDate() + n);
    return formatDateISO(d);
  }

  // ---------- logical day math (DAY_START_HOUR offset) ----------
  // The "logical day" is the date the user mentally considers today, with
  // an N-hour rollover. Mirrors User#perceived_today (3am) and
  // agenda.js#dayKey.
  function logicalDayStart(dateObj, dayStartHour) {
    // Date instance representing dayStartHour:00 of the logical day
    // containing `dateObj`. If we're before dayStartHour locally, that
    // logical day is the previous calendar date.
    const d = new Date(dateObj);
    d.setHours(dayStartHour, 0, 0, 0);
    if (dateObj < d) d.setDate(d.getDate() - 1);
    return d;
  }
  function logicalDateISO(dateObj, dayStartHour) {
    return formatDateISO(logicalDayStart(dateObj, dayStartHour));
  }

  // ---------- click suppression after drag mouseup ----------
  // Some browsers synthesize a `click` event after a drag's mouseup
  // (especially when the drag movement was small). That synthesized
  // click bubbles to modals.js's `$(document).click` handler, which
  // hides any open modal whose target isn't inside one — closing the
  // modal we just opened from the drag-finish. We intercept the next
  // click on the capture phase and swallow it. Time-limited to 500ms
  // so a real click later doesn't get silently dropped.
  let suppressClickUntil = 0;
  function armClickSuppressor() { suppressClickUntil = Date.now() + 500; }
  document.addEventListener("click", (e) => {
    if (Date.now() >= suppressClickUntil) return;
    suppressClickUntil = 0;
    e.stopPropagation();
    e.stopImmediatePropagation?.();
    e.preventDefault();
  }, true);

  // ---------- add-modal openers ----------
  function ensureEventKind(modal) {
    const eventBtn = modal.querySelector(".kind-btn[data-kind='event']");
    if (eventBtn && !eventBtn.classList.contains("active")) eventBtn.click();
  }
  function setAllDay(modal, on) {
    const cb = modal.querySelector(".add-allday-input");
    if (!cb) return;
    if (cb.checked === !!on) return;
    cb.checked = !!on;
    cb.dispatchEvent(new Event("change", { bubbles: true }));
  }
  // agenda.js binds a `modal.shown` jQuery handler that calls
  // applyDefaultStartTime() — which silently overwrites whatever start
  // time we just set with either "next top of hour" or "09:00".
  // Registering a `.one()` handler that fires AFTER agenda.js's
  // (because we register after it) and re-applies our values is the
  // least-invasive fix. (Without this, every double-click on the time
  // grid landed in the add modal at 9am no matter where the click was.)
  function afterModalShown(modal, fn) {
    if (!window.jQuery) { fn(); return; }
    window.jQuery(modal).one("modal.shown", fn);
  }
  function openAddModal(modal) {
    if (window.showModal) window.showModal(`#${modal.id}`);
  }
  function openAddModalForDate(dateStr) {
    const modal = $("#agenda-add-modal");
    if (!modal) return;
    ensureEventKind(modal);
    setAllDay(modal, false);
    const dateInput = modal.querySelector(".add-date");
    if (dateInput && dateStr) dateInput.value = dateStr;
    openAddModal(modal);
  }
  function openAddModalForRange(startDate, endDate, allDay) {
    const modal = $("#agenda-add-modal");
    if (!modal) return;
    ensureEventKind(modal);
    setAllDay(modal, !!allDay);
    const dateInput = modal.querySelector(".add-date");
    if (dateInput) dateInput.value = startDate;
    const endDateInput = modal.querySelector(".add-end-date");
    if (endDateInput) endDateInput.value = endDate;
    openAddModal(modal);
  }
  function openAddModalForTime(dateStr, startMin, endMin) {
    const modal = $("#agenda-add-modal");
    if (!modal) return;
    ensureEventKind(modal);
    setAllDay(modal, false);
    const dateInput = modal.querySelector(".add-date");
    if (dateInput) dateInput.value = dateStr;
    // End-date input lives in a normally-hidden row and resetForm fills
    // it with form.dataset.defaultDate (today). Without this line, a
    // drag on a non-today column leaves endDate stuck on today — submit
    // then computes end_at against today, producing a negative
    // duration (server rejects or the optimistic tile collapses to the
    // renderer's 15-min visual minimum).
    const endDateInput = modal.querySelector(".add-end-date");
    if (endDateInput) endDateInput.value = dateStr;
    afterModalShown(modal, () => {
      const startInput = modal.querySelector(".add-start");
      if (startInput) startInput.value = formatTimeHHMM(startMin);
      const endInput = modal.querySelector(".add-end");
      if (endInput) endInput.value = formatTimeHHMM(endMin);
    });
    openAddModal(modal);
  }

  // ---------- shared state (module-scope, NOT per-init) ----------
  // Drag state lives outside the init functions so re-init after a live
  // HTML swap doesn't shadow it and document-level handlers stay correct.
  const monthDrag = { startCell: null, lastCell: null, moved: false };

  // Mobile month-view infinite scroll state. `edgeObserver` watches the
  // up/down loader sentinels and prepends/appends month blocks as the
  // user nears either edge. `titleObserver` syncs the toolbar title to
  // whichever block dominates the viewport. Both are torn down + rebuilt
  // on every full DOM swap (renderMonthFor + the mobile media-query
  // transitioning above its breakpoint).
  const mobileInfinite = {
    observed: false,
    mql: null,
    scrollHandler: null,
    scrollGrid: null,
    // Flipped true on the first real user gesture against the grid.
    // Until then the edge loader is inert — neutralises the initial
    // layout's programmatic scroll-to-today, which would otherwise
    // look like an "approach the bottom" signal and chain loads.
    userInteracted: false,
    // Hard cooldown: at most one load every LOAD_COOLDOWN_MS, no
    // matter how many scroll events queue up. This is what stops the
    // "phone-down self-scrolling" cascade where a JS-blocked frame
    // backed up scroll events that then all fired loads in sequence.
    loading: false,
    lastLoadAt: 0,
  };
  const weekDrag = { col: null, startPx: 0, top: 0, bottom: 0, sel: null, moved: false, ctx: null };
  // All-day strip drag-to-create state. `startCell` is where mousedown
  // fired; `currentCell` is whichever all-day cell the cursor is over
  // right now. Both stay null when no drag is in flight.
  const allDayDrag = { startCell: null, currentCell: null, moved: false, root: null };
  // Event-drag state. mousedown on an editable event puts us in a
  // "maybe-drag" state; mousemove past a threshold promotes it to a real
  // drag with a cursor-following ghost and a drop-slot placeholder.
  // The original event stays in place at reduced opacity so the user
  // can see where it's moving FROM. Pressing Escape mid-drag cancels.
  const eventDrag = {
    btn: null, startX: 0, startY: 0, moved: false, ctx: null,
    ghost: null, placeholder: null, dropCol: null, dropTop: 0,
    grabOffsetY: 0, // px from event top to where the user grabbed it
  };

  // Mirror state for read-only events. We don't promote them to a real
  // drag (the data isn't ours to edit), but we DO track the attempt so
  // the cursor can flip to `not-allowed` the moment the user moves past
  // the threshold — a tactile "no, you can't drag this" hint. Click
  // (= no movement) still falls through to the details modal.
  const eventDragBlocked = { btn: null, startX: 0, startY: 0, moved: false };

  function clearBlockedDrag() {
    eventDragBlocked.btn = null;
    eventDragBlocked.moved = false;
    document.body.classList.remove("cal-event-drag-blocked");
  }

  function cancelEventDrag() {
    if (!eventDrag.btn) return;
    eventDrag.btn.classList.remove("is-dragging-source");
    eventDrag.btn.style.pointerEvents = "";
    if (eventDrag.ghost) { eventDrag.ghost.remove(); eventDrag.ghost = null; }
    if (eventDrag.placeholder) { eventDrag.placeholder.remove(); eventDrag.placeholder = null; }
    eventDrag.btn = null;
    eventDrag.moved = false;
    eventDrag.ctx = null;
    eventDrag.dropCol = null;
    document.body.classList.remove("cal-event-dragging");
  }

  // Build a UTC epoch (seconds) for `minutesAfterDayStart` minutes past
  // `dayStart` on the local calendar `dateISO`. The date string IS the
  // logical day (3am-anchored), so a slot 23:30 minutes past the 3am
  // start lands on the *next* calendar day at 2:30am.
  function computeEpochForLogicalSlot(dateISO, dayStart, minutesAfterDayStart) {
    const [y, m, d] = dateISO.split("-").map(Number);
    const totalMin = dayStart * 60 + minutesAfterDayStart;
    const dayOffset = Math.floor(totalMin / (24 * 60));
    const clockMin = ((totalMin % (24 * 60)) + (24 * 60)) % (24 * 60);
    const local = new Date(y, m - 1, d + dayOffset, Math.floor(clockMin / 60), clockMin % 60, 0, 0);
    return Math.floor(local.getTime() / 1000);
  }

  // Update the button's top/height/parent without rebuilding the whole
  // week. `applyInlineMove` is called BEFORE `sendEventMove` so the user
  // sees the event in its new slot immediately; the PATCH happens in the
  // background. (The previous version called `buildWeekBlocks` after the
  // drag — which removed and rebuilt every event in the week, making
  // every click that registered as a tiny drag look like the clicked
  // event "disappeared".)
  function applyInlineMove(btn, dropCol, newTopPx, pxPerMin) {
    const origStart = Number(btn.dataset.startAt);
    const origEnd = Number(btn.dataset.endAt) || origStart;
    const durMin = Math.max(15, Math.round((origEnd - origStart) / 60));
    const grid = btn.closest(".cal-week-grid");
    const pxPerMinSafe = pxPerMin || weekPxPerMin(grid);
    const newHeight = Math.max(14, durMin * pxPerMinSafe - 2);
    btn.style.top = `${newTopPx}px`;
    btn.style.height = `${newHeight}px`;
    btn.style.left = "2px";
    btn.style.width = "";
    btn.style.right = "2px";
    if (dropCol !== btn.parentElement) dropCol.appendChild(btn);
  }

  // Drag-to-move goes through AgendaMutationQueue (same path as modal
  // edits), so the pending-sync badge surfaces while the queue drains,
  // the SW's synthetic 503 keeps the op queued for replay when offline,
  // and a permanent 4xx lands in the dropped-bucket banner.
  // Snapshot the tile's DOM position + style + epoch dataset before the
  // optimistic inline move runs, so the recurring-scope-modal "Cancel"
  // path can restore the tile to exactly where it started. Captured
  // BEFORE applyInlineMove mutates style; restored without rebuilding
  // the week (same reasons applyInlineMove avoids buildWeekBlocks).
  function captureTileState(btn) {
    const timeLabel = btn.querySelector(".cal-week-event-time");
    return {
      parent:      btn.parentElement,
      nextSibling: btn.nextElementSibling,
      top:         btn.style.top,
      height:      btn.style.height,
      left:        btn.style.left,
      right:       btn.style.right,
      width:       btn.style.width,
      startAt:     btn.dataset.startAt,
      endAt:       btn.dataset.endAt,
      timeLabel:   timeLabel,
      timeText:    timeLabel ? timeLabel.textContent : null,
    };
  }

  function revertTileState(btn, snap) {
    if (snap.parent && btn.parentElement !== snap.parent) {
      snap.parent.insertBefore(btn, snap.nextSibling);
    }
    btn.style.top    = snap.top    || "";
    btn.style.height = snap.height || "";
    btn.style.left   = snap.left   || "";
    btn.style.right  = snap.right  || "";
    btn.style.width  = snap.width  || "";
    if (snap.startAt != null) btn.dataset.startAt = snap.startAt;
    if (snap.endAt   != null) btn.dataset.endAt   = snap.endAt;
    if (snap.timeLabel && snap.timeText != null) snap.timeLabel.textContent = snap.timeText;
  }

  // Refresh the tile's inner time label so the optimistic move shows the
  // new clock range, not the original ("8pm – 11pm" → "5pm – 8pm").
  // Mirrors the formatting used at tile-build time in buildWeekBlocks.
  function applyInlineTimeLabel(btn, newStartAt, newEndAt) {
    const timeLabel = btn.querySelector(".cal-week-event-time");
    if (!timeLabel) return;
    const startMin = epochToClockMinutes(newStartAt);
    const endMin = epochToClockMinutes(newEndAt);
    timeLabel.textContent = (newEndAt && newEndAt !== newStartAt)
      ? `${formatLabelTime(startMin)} – ${formatLabelTime(endMin)}`
      : formatLabelTime(startMin);
  }

  function epochToClockMinutes(epoch) {
    const d = new Date(Number(epoch) * 1000);
    return d.getHours() * 60 + d.getMinutes();
  }

  // Long-form "Tue Jun 30 · 8:00pm – 11:00pm" for the recurring-scope
  // modal's before/after diff. Days only differ when the drop crosses a
  // day boundary, so the date prefix is always shown — keeps the layout
  // stable and makes a cross-day move unambiguous.
  function formatRangeLong(startAt, endAt) {
    const startD = new Date(Number(startAt) * 1000);
    const endD = new Date(Number(endAt) * 1000);
    const date = startD.toLocaleDateString(undefined, {
      weekday: "short", month: "short", day: "numeric",
    });
    const startMin = startD.getHours() * 60 + startD.getMinutes();
    const endMin = endD.getHours() * 60 + endD.getMinutes();
    const range = (endAt && endAt !== startAt)
      ? `${formatLabelTime(startMin)} – ${formatLabelTime(endMin)}`
      : formatLabelTime(startMin);
    return `${date} · ${range}`;
  }

  // Compact range without the date prefix — "8pm – 11pm" — for the
  // pattern row of the recurring-scope modal where the date is already
  // implied by the description ("Fridays").
  function formatRangeShort(startAt, endAt) {
    const startD = new Date(Number(startAt) * 1000);
    const endD = new Date(Number(endAt) * 1000);
    const startMin = startD.getHours() * 60 + startD.getMinutes();
    const endMin = endD.getHours() * 60 + endD.getMinutes();
    return (endAt && endAt !== startAt)
      ? `${formatLabelTime(startMin)} – ${formatLabelTime(endMin)}`
      : formatLabelTime(startMin);
  }

  // Turn a recurrence rule + the occurrence's anchor date into a human
  // phrase: "Fridays", "Every 21st", "The second Tuesday of every month",
  // "Yearly on July 3", "Every 3 days". Mirrors the recurrence shapes
  // supported by AgendaSchedule + the BE's shift_recurrence helper.
  function describeRecurrence(rule, anchorEpoch) {
    if (!rule || !rule.freq) return null;
    const interval = Math.max(1, Number(rule.interval) || 1);
    const wkeys = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
    const wplural = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"];
    const wsingle = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
    const anchor = anchorEpoch ? new Date(Number(anchorEpoch) * 1000) : null;
    const ord = (n) => {
      const s = ["th", "st", "nd", "rd"];
      const v = Math.abs(n) % 100;
      return n < 0 ? "the last" : `the ${n}${s[(v - 20) % 10] || s[v] || s[0]}`;
    };
    const setPosName = (p) => ({ 1: "first", 2: "second", 3: "third", 4: "fourth", "-1": "last" })[p] || `${p}`;
    const joinList = (xs) => xs.length <= 1 ? (xs[0] || "") : xs.length === 2 ? xs.join(" and ") : `${xs.slice(0, -1).join(", ")}, and ${xs[xs.length - 1]}`;

    // Shared describers for the weekly / monthly shapes. Both `weekly`
    // and `custom`+`unit=week` route through `describeWeekly`; both
    // `monthly` and `custom`+`unit=month` route through `describeMonthly`.
    // Without this routing, a custom-month rule with by_set_pos+by_day
    // (e.g. "every 1st Friday") collapsed to a bare "Every month".
    const describeWeekly = (n) => {
      const days = (rule.by_day && rule.by_day.length)
        ? rule.by_day.map((k) => wkeys.indexOf(String(k).toLowerCase())).filter((i) => i >= 0)
        : (anchor ? [anchor.getDay()] : []);
      if (n === 1) return joinList(days.map((i) => wplural[i])) || "Weekly";
      return `Every ${n} weeks on ${joinList(days.map((i) => wsingle[i]))}`;
    };
    const describeMonthly = (n) => {
      if (rule.by_set_pos && rule.by_day && rule.by_day.length) {
        const wi = wkeys.indexOf(String(rule.by_day[0]).toLowerCase());
        const dayName = wi >= 0 ? wsingle[wi] : "day";
        const pos = setPosName(Number(rule.by_set_pos));
        return n === 1
          ? `The ${pos} ${dayName} of every month`
          : `The ${pos} ${dayName} of every ${n} months`;
      }
      const days = (rule.by_month_day && rule.by_month_day.length)
        ? rule.by_month_day.map((d) => Number(d))
        : (anchor ? [anchor.getDate()] : []);
      const desc = joinList(days.map((d) => ord(d)));
      return n === 1 ? `Monthly on ${desc}` : `Every ${n} months on ${desc}`;
    };

    switch (String(rule.freq).toLowerCase()) {
      case "daily":
        return interval === 1 ? "Every day" : `Every ${interval} days`;
      case "weekdays":
        return "Weekdays";
      case "weekly":
        return describeWeekly(interval);
      case "monthly":
        return describeMonthly(interval);
      case "yearly": {
        if (!anchor) return "Yearly";
        const month = anchor.toLocaleString(undefined, { month: "long" });
        return `Yearly on ${month} ${ord(anchor.getDate()).replace(/^the /, "")}`;
      }
      case "custom": {
        const unit = String(rule.unit || "day").toLowerCase();
        if (unit === "week")  return describeWeekly(interval);
        if (unit === "month") return describeMonthly(interval);
        // Default unit=day fallback.
        return interval === 1 ? "Every day" : `Every ${interval} days`;
      }
      default: return null;
    }
  }

  // Read the recurrence rule embedded in the tile's `data-schedule`
  // attribute (server-rendered by AgendaItem#presentation_attrs). Returns
  // null for non-recurring tiles or for malformed JSON — caller treats
  // null as "no pattern row in the modal."
  function readScheduleRecurrence(btn) {
    const raw = btn?.dataset?.schedule;
    if (!raw || raw === "null") return null;
    try {
      const sched = JSON.parse(raw);
      if (!sched || !sched.freq) return null;
      // serialize_for_edit flattens these to top-level; reshape into the
      // {freq, by_day, ...} envelope describeRecurrence expects.
      return {
        freq:         sched.freq,
        interval:     sched.interval,
        unit:         sched.unit,
        by_day:       sched.by_day || [],
        by_month_day: sched.by_month_day || [],
        by_set_pos:   sched.by_set_pos,
      };
    } catch (_e) {
      return null;
    }
  }

  // Mirror the BE's shift_recurrence: rewrite the rule so it anchors on
  // the NEW date instead of the OLD one. Used only for the modal preview;
  // the canonical shift happens server-side.
  function shiftRecurrencePreview(rule, oldEpoch, newEpoch) {
    if (!rule || !oldEpoch || !newEpoch) return rule;
    const oldD = new Date(Number(oldEpoch) * 1000);
    const newD = new Date(Number(newEpoch) * 1000);
    const oldDate = `${oldD.getFullYear()}-${oldD.getMonth() + 1}-${oldD.getDate()}`;
    const newDate = `${newD.getFullYear()}-${newD.getMonth() + 1}-${newD.getDate()}`;
    if (oldDate === newDate) return rule;

    const wkeys = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];
    const oldW = wkeys[oldD.getDay()];
    const newW = wkeys[newD.getDay()];
    const next = { ...rule };
    if (Array.isArray(rule.by_day) && rule.by_day.length) {
      next.by_day = rule.by_day.map((k) => String(k).toLowerCase() === oldW ? newW : String(k).toLowerCase());
    }
    if (Array.isArray(rule.by_month_day) && rule.by_month_day.length) {
      next.by_month_day = rule.by_month_day.map((d) => Number(d) === oldD.getDate() ? newD.getDate() : Number(d));
    }
    if (rule.by_set_pos) {
      const plus7 = new Date(newD.getFullYear(), newD.getMonth(), newD.getDate() + 7);
      next.by_set_pos = plus7.getMonth() !== newD.getMonth() ? -1 : Math.floor((newD.getDate() - 1) / 7) + 1;
    }
    return next;
  }

  // Enqueues the PATCH for a confirmed move. `scope` is one of
  // "occurrence" | "future" | null (null = non-recurring). Drag-to-move
  // goes through AgendaMutationQueue (same path as modal edits), so the
  // pending-sync badge surfaces while the queue drains, the SW's
  // synthetic 503 keeps the op queued for replay when offline, and a
  // permanent 4xx lands in the dropped-bucket banner.
  function commitEventMove(btn, newStartAt, newEndAt, scope) {
    const itemId = btn.dataset.itemId;
    if (!itemId) return;
    btn.dataset.startAt = String(newStartAt);
    btn.dataset.endAt = String(newEndAt);

    const url = `/agenda_items/${itemId}`;
    const mid = window.AgendaMutationQueue.newMutationId();
    const payload = {
      agenda_item: {
        start_at:           newStartAt,
        end_at:             newEndAt,
        client_mutation_id: mid,
      },
    };
    if (scope) payload.agenda_item.scope = scope;

    btn.classList.add("is-pending");
    window.AgendaMutationQueue.enqueue({
      client_mutation_id: mid,
      kind:               "update",
      url,
      method:             "PATCH",
      body:               payload,
      target_id:          String(itemId),
      dedup_key:          `update:${url}`,
    });
    window.AgendaMutationQueue.flush();
  }

  // Top-level move dispatcher. For non-recurring items, commits
  // immediately. For recurring items, opens the three-way scope modal
  // (just this / this and following / cancel) and either commits with
  // the chosen scope or reverts the tile to `snap`. The tile is already
  // optimistically moved in the DOM by the time this runs.
  function sendEventMove(btn, newStartAt, newEndAt, snap) {
    const recurring = btn.dataset.recurring === "true";
    if (!recurring) {
      commitEventMove(btn, newStartAt, newEndAt, null);
      return;
    }
    const title = btn.dataset.name || "this event";
    // Build a before/after diff from the snapshot's preserved epochs vs
    // the dropped position, so the user sees exactly what they're about
    // to change. Snap captured the dataset BEFORE applyInlineMove
    // mutated it, so snap.startAt/endAt are the original values.
    const from = (snap && snap.startAt)
      ? formatRangeLong(snap.startAt, snap.endAt || snap.startAt)
      : null;
    const to = formatRangeLong(newStartAt, newEndAt);
    // Pattern row — only when the tile carries a recurrence rule. The
    // BE shifts the rule to anchor on the new occurrence date; preview
    // the same shift locally so the modal copy reflects what
    // "This and following" would actually do.
    let patternFrom = null;
    let patternTo = null;
    const rule = readScheduleRecurrence(btn);
    if (rule) {
      const beforeDesc = describeRecurrence(rule, snap?.startAt);
      const shifted = shiftRecurrencePreview(rule, snap?.startAt, newStartAt);
      const afterDesc = describeRecurrence(shifted, newStartAt);
      if (beforeDesc) patternFrom = `${beforeDesc} at ${formatRangeShort(snap.startAt, snap.endAt || snap.startAt)}`;
      if (afterDesc)  patternTo   = `${afterDesc} at ${formatRangeShort(newStartAt, newEndAt)}`;
    }
    const choose = (window.AgendaRecurringScope)
      ? window.AgendaRecurringScope({ title, from, to, patternFrom, patternTo })
      : Promise.resolve("occurrence");
    choose.then((choice) => {
      if (choice === "occurrence" || choice === "future") {
        commitEventMove(btn, newStartAt, newEndAt, choice);
      } else if (snap) {
        revertTileState(btn, snap);
      }
    });
  }

  // ============================================================
  // MONTH VIEW
  // ============================================================
  function initMonthView(root) {
    const grid = $(".cal-month-grid", root);
    if (!grid) return;

    // Capture the load-time "anchored to today" state + paint the initial
    // Today-pill state. Both happen before the listeners bind so the very
    // first rollover tick sees a populated dataset flag.
    setAnchoredToToday(root, 3);
    updateTodayBtnState(root, 3);

    // -- listeners delegated to the root so an HTML grid swap doesn't
    //    invalidate them. Marked with a guard attribute so calling
    //    initMonthView() multiple times only binds once.
    if (!root.hasAttribute("data-cal-bound")) {
      root.setAttribute("data-cal-bound", "");
      bindMonthHandlers(root);
      bindCommonHandlers();
      scheduleDayRollover(root);
      installRefreshTriggers(root);
      installNavInterception(root);
      installCalJumpHook(root);
      // AgendaStore is the data source for both halves of the month view
      // (timed cells via month_view.js, all-day banners via this file's
      // layoutMonthBanners). Without this boot the page sees no items
      // until a navigation event and stays blank — the gap that made
      // /agenda/month look broken even when other views worked.
      bootAgendaStore(root);
    }

    // -- everything else runs every time, since the grid contents change.
    rehydrateMonthSeedsFromStore(root);
    layoutMonthBanners(root);
    recountMonthOverflow(root);
    // Mobile only: turn the single server-rendered month into a stack
    // of months with infinite vertical scroll. No-op on desktop and on
    // re-mount when already activated for the current DOM.
    activateMobileMonthInfinite(root);
  }

  // Refill the hidden `[data-month-allday-seeds]` container from the
  // store's view of the visible-block range. layoutMonthBanners reads
  // from those seed nodes to lay out the row-spanning all-day banners.
  // No-op if the store/hydrator aren't loaded yet.
  function rehydrateMonthSeedsFromStore(root) {
    if (!window.AgendaSeedHydrator || !window.AgendaStore) return;
    const grid = $(".cal-month-grid", root);
    if (!grid) return;
    const seedsContainer = $("[data-month-allday-seeds]", grid);
    if (!seedsContainer) return;
    const from = grid.dataset.monthStart;
    const to = grid.dataset.monthEnd;
    if (!from || !to) return;
    window.AgendaSync?.ensureRangeLoaded(from, to);
    window.AgendaSeedHydrator.hydrateMonthAllDaySeeds(seedsContainer, from, to);
  }

  function bindMonthHandlers(root) {
    const findCell = (e) => e.target.closest(".cal-month-cell[data-date]");

    root.addEventListener("mousedown", (e) => {
      if (e.button !== 0) return;
      if (e.target.closest(".cal-month-item, .cal-month-banner")) return;
      const cell = findCell(e);
      if (!cell || !root.querySelector(".cal-month-grid").contains(cell)) return;
      // Mobile: cell tap drills into /agenda/day. Skip the drag-create
      // setup so the click registers cleanly. Event-pill / banner taps
      // still open details (early-return above) and the toolbar's `+`
      // button is the explicit add-event affordance.
      if (isMobileMonthView()) return;
      e.preventDefault();
      monthDrag.startCell = cell;
      monthDrag.lastCell = cell;
      monthDrag.moved = false;
    });

    // Mobile single-tap → /agenda/day for that date. Listening on click
    // (not mousedown) so the tap reads as a click in both pointer and
    // touch contexts, and so event-pill clicks bubble to their own
    // open-details handler first without being eaten here.
    root.addEventListener("click", (e) => {
      if (!isMobileMonthView()) return;
      if (e.defaultPrevented) return;
      if (e.target.closest(".cal-month-item, .cal-month-banner")) return;
      const cell = findCell(e);
      if (!cell || !root.querySelector(".cal-month-grid").contains(cell)) return;
      const date = cell.dataset.date;
      if (!date) return;
      e.preventDefault();
      window.location.assign(`/agenda?date=${date}`);
    });

    root.addEventListener("dblclick", (e) => {
      if (e.target.closest(".cal-month-item, .cal-month-banner")) return;
      // Mobile uses single-tap → day view; double-tap-create would
      // conflict with that and adds zero affordance on touch.
      if (isMobileMonthView()) return;
      const cell = findCell(e);
      if (!cell || !root.querySelector(".cal-month-grid").contains(cell)) return;
      openAddModalForDate(cell.dataset.date);
    });

    root.addEventListener("keydown", (e) => {
      if (e.key !== "Enter" && e.key !== " ") return;
      const cell = findCell(e);
      if (!cell || e.target !== cell) return;
      e.preventDefault();
      openAddModalForDate(cell.dataset.date);
    });

    // Re-flow banners + overflow on resize.
    window.addEventListener("resize", () => {
      layoutMonthBanners(root);
      recountMonthOverflow(root);
    });
  }

  function clearMonthDragHighlight(root) {
    $$(".cal-month-cell.cal-drag-target", root).forEach((c) => c.classList.remove("cal-drag-target"));
  }

  function paintMonthDragRange(root, startCell, endCell) {
    const a = startCell.dataset.date;
    const b = endCell.dataset.date;
    const lo = compareISO(a, b) <= 0 ? a : b;
    const hi = compareISO(a, b) <= 0 ? b : a;
    $$(".cal-month-cell", root).forEach((cell) => {
      const d = cell.dataset.date;
      const inRange = d && compareISO(d, lo) >= 0 && compareISO(d, hi) <= 0;
      cell.classList.toggle("cal-drag-target", !!inRange);
    });
  }

  // Compute lanes per week-row and render banners. Multi-day spans get
  // split at the row boundary; the segment that ends at row-end gets
  // .is-continued-right, and the next row's segment gets .is-continued-left.
  function layoutMonthBanners(root) {
    const rows = $$(".cal-month-row", root);
    const allSeeds = $$("[data-month-allday-seeds] .cal-month-allday-seed", root);

    rows.forEach((row) => {
      const layer = row.querySelector("[data-row-banners]");
      if (!layer) return;
      layer.innerHTML = "";

      const cells = $$(".cal-month-cell", row);
      if (cells.length !== 7) {
        row.style.setProperty("--cal-banner-rows", 0);
        return;
      }
      const rowStart = cells[0].dataset.date;
      const rowEnd = cells[6].dataset.date;

      // When the stack holds multiple month-blocks (mobile infinite
      // scroll), each row "belongs" to exactly ONE month. Without
      // clipping, an event on Jan 30 would render in BOTH the Jan
      // block's last row AND the Feb block's first row (both rows
      // physically contain Jan 30 — as current-month and as other-month
      // spill-over respectively), producing a visible duplicate.
      // Clamp the row's effective range to its block's month so each
      // banner appears in exactly one block; multi-month spans split at
      // the month boundary with proper continued-left/right cues.
      const block = row.closest("[data-month-block]");
      let inMonthStart = rowStart;
      let inMonthEnd = rowEnd;
      if (block && block.dataset.monthIso) {
        const [yy, mm] = block.dataset.monthIso.split("-").map(Number);
        const monthFirstISO = `${yy}-${String(mm).padStart(2, "0")}-01`;
        const lastDay = new Date(yy, mm, 0).getDate();
        const monthLastISO = `${yy}-${String(mm).padStart(2, "0")}-${String(lastDay).padStart(2, "0")}`;
        if (compareISO(monthFirstISO, inMonthStart) > 0) inMonthStart = monthFirstISO;
        if (compareISO(monthLastISO, inMonthEnd) < 0) inMonthEnd = monthLastISO;
      }
      // No overlap at all → row is entirely other-month (shouldn't
      // happen in practice but kept for safety).
      if (compareISO(inMonthStart, rowEnd) > 0 || compareISO(inMonthEnd, rowStart) < 0) {
        row.style.setProperty("--cal-banner-rows", 0);
        return;
      }

      // Each candidate banner clamped to this row's in-month window.
      const candidates = [];
      allSeeds.forEach((seed) => {
        const startEpoch = Number(seed.dataset.startAt);
        if (!startEpoch) return;
        // Agenda-toggle hides remove the banner entirely (no banner DOM
        // built, nothing for `applyAgendaVisibility` to mark later).
        // Item / pattern / declined hides still flow through and get
        // tagged `.hidden-by-filter` by the post-hoc pass.
        if (window.__agendaSeedShouldRemove?.(seed)) return;
        const startDateISO = formatDateISO(new Date(startEpoch * 1000));
        const endRaw = Number(seed.dataset.endDate) || startEpoch;
        const endDateISO = formatDateISO(new Date(endRaw * 1000));
        // Overlap with the row's in-month window?
        if (compareISO(endDateISO, inMonthStart) < 0) return;
        if (compareISO(startDateISO, inMonthEnd) > 0) return;
        const segStart = compareISO(startDateISO, inMonthStart) < 0 ? inMonthStart : startDateISO;
        const segEnd = compareISO(endDateISO, inMonthEnd) > 0 ? inMonthEnd : endDateISO;
        candidates.push({
          seed, segStart, segEnd,
          // Continuation cues fire when the EVENT extends past the row
          // window (either physical row bounds or the in-month clip).
          // Both produce a "→" / "←" hint on the appropriate edge.
          continuedLeft: compareISO(startDateISO, inMonthStart) < 0,
          continuedRight: compareISO(endDateISO, inMonthEnd) > 0,
        });
      });

      // Stable order: earlier start first, then longer span first so big
      // multi-day events anchor to the top lane.
      candidates.sort((a, b) => {
        const c = compareISO(a.segStart, b.segStart);
        if (c !== 0) return c;
        return compareISO(b.segEnd, a.segEnd);
      });

      // Lane packing — each lane stores the latest segEnd it holds.
      const lanes = [];
      candidates.forEach((c) => {
        let placed = false;
        for (let i = 0; i < lanes.length; i++) {
          if (compareISO(lanes[i], c.segStart) < 0) {
            lanes[i] = c.segEnd;
            c.lane = i;
            placed = true;
            break;
          }
        }
        if (!placed) {
          c.lane = lanes.length;
          lanes.push(c.segEnd);
        }
      });

      // Each cell is `100/7 %` wide.
      const pct = 100 / 7;
      // Measure the actual day-num band height instead of hardcoding —
      // the mobile media query enlarges cell-head substantially (~46px)
      // vs. desktop (~22px), and a hardcoded reservedTop was overlapping
      // banners onto day numbers. Use the first cell's cell-head bottom
      // (relative to the row) + a 2px breath; falls back to 22 if the
      // measurement isn't ready (e.g. row hidden on initial render).
      const firstHead = cells[0].querySelector(".cal-month-cell-head");
      let reservedTop = 22;
      if (firstHead) {
        const rowRect = row.getBoundingClientRect();
        const headRect = firstHead.getBoundingClientRect();
        const measured = (headRect.bottom - rowRect.top) + 2;
        if (measured > 0 && Number.isFinite(measured)) reservedTop = measured;
      }
      const mobile = isMobileMonthView();
      const bannerHeight = mobile ? 18 : 17;
      const bannerGap = 2;

      candidates.forEach((c) => {
        const startCol = (new Date(c.segStart + "T12:00:00").getTime() - new Date(rowStart + "T12:00:00").getTime()) / (24 * 3600 * 1000);
        const span = (new Date(c.segEnd + "T12:00:00").getTime() - new Date(c.segStart + "T12:00:00").getTime()) / (24 * 3600 * 1000) + 1;
        const node = buildBannerNode(c.seed);
        if (c.continuedLeft) node.classList.add("is-continued-left");
        if (c.continuedRight) node.classList.add("is-continued-right");
        node.style.left = `calc(${startCol * pct}% + 2px)`;
        node.style.width = `calc(${span * pct}% - 4px)`;
        node.style.top = `${reservedTop + c.lane * (bannerHeight + bannerGap)}px`;
        node.style.height = `${bannerHeight}px`;
        layer.appendChild(node);
      });

      // Items get pushed down by the LAYOUT height, not the rendered
      // banner height — keep in sync with bannerHeight + bannerGap so
      // banners and items never collide.
      row.style.setProperty("--cal-banner-rows", lanes.length);
      row.style.setProperty("--cal-banner-row-h", `${bannerHeight + bannerGap}px`);
    });
  }

  function buildBannerNode(seed) {
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "cal-month-banner agenda-item-data";
    btn.setAttribute("data-open-details", "");
    copyDataAttrs(seed, btn);
    const c = seed.dataset.agendaColor || seed.dataset.color || "#888";
    btn.style.setProperty("--agenda-color", c);
    btn.textContent = seed.dataset.name || "";
    return btn;
  }

  function recountMonthOverflow(root) {
    $$(".cal-month-cell", root).forEach((cell) => {
      const container = cell.querySelector("[data-items-container]");
      const overflow = cell.querySelector(".cal-month-overflow");
      if (!container || !overflow) return;
      const items = Array.from(container.children).filter((c) => !c.classList.contains("hidden-by-filter"));
      items.forEach((it) => it.classList.remove("is-clipped"));
      const containerRect = container.getBoundingClientRect();
      let hidden = 0;
      items.forEach((it) => {
        const r = it.getBoundingClientRect();
        if (r.bottom > containerRect.bottom + 0.5) {
          it.classList.add("is-clipped");
          hidden++;
        }
      });
      if (hidden > 0) {
        overflow.textContent = `${hidden} more`;
        overflow.classList.remove("hidden");
      } else {
        overflow.textContent = "";
        overflow.classList.add("hidden");
      }
    });
  }

  function copyDataAttrs(from, to) {
    for (const attr of from.attributes) {
      if (attr.name.startsWith("data-")) to.setAttribute(attr.name, attr.value);
    }
  }

  // Paint a thin colored breadcrumb in each day column's left gutter for
  // every seed the filter hid. Sized by the seed's per-segment time
  // range so the mark sits where the event would have rendered.
  function paintHiddenGutters(root, hiddenTimedSegs, pxPerMin) {
    if (!root) return;
    root.querySelectorAll(".cal-week-hidden-mark").forEach((n) => n.remove());
    (hiddenTimedSegs || []).forEach(({ seed, seg, col }) => {
      const gutter = col?.querySelector("[data-hidden-gutter]");
      if (!gutter) return;
      const kind = seed.dataset.kind || "event";
      const isPoint = kind === "task" || kind === "trigger";
      const durationMin = isPoint ? 15 : Math.max(15, seg.endMin - seg.startMin);
      const top = seg.startMin * pxPerMin;
      const height = Math.max(8, durationMin * pxPerMin - 2);
      const mark = document.createElement("div");
      mark.className = "cal-week-hidden-mark";
      mark.style.top = `${top}px`;
      mark.style.height = `${height}px`;
      const color = seed.dataset.agendaColor || seed.dataset.color || "#888";
      mark.style.setProperty("--mark-color", color);
      // Copy every data-* attr off the seed so the click handler can
      // rebuild the details modal verbatim.
      for (const attr of seed.attributes) {
        if (attr.name.startsWith("data-")) mark.setAttribute(attr.name, attr.value);
      }
      gutter.appendChild(mark);
    });
  }

  function openHiddenListAt(mark, e) {
    const gutter = mark.parentElement;
    if (!gutter) return;
    const gutterRect = gutter.getBoundingClientRect();
    const clickY = e.clientY - gutterRect.top;
    const all = Array.from(gutter.querySelectorAll(".cal-week-hidden-mark"));
    // Marks whose y-range covers the click point (inclusive). Single-mark
    // clicks degenerate to a one-item list.
    const overlapping = all.filter((m) => {
      const t = parseFloat(m.style.top) || 0;
      const h = parseFloat(m.style.height) || 0;
      return clickY >= t && clickY <= t + h;
    });
    const items = (overlapping.length > 0 ? overlapping : [mark]);
    populateHiddenListModal(items);
    if (window.showModal) window.showModal("#agenda-hidden-list");
  }

  function populateHiddenListModal(marks) {
    const list = document.querySelector("#agenda-hidden-list [data-hidden-list]");
    if (!list) return;
    list.innerHTML = "";
    marks.forEach((mark) => {
      const li = document.createElement("li");
      li.className = "agenda-hidden-list-item";
      const dot = document.createElement("span");
      dot.className = "agenda-hidden-list-dot";
      dot.style.background = mark.dataset.agendaColor || mark.dataset.color || "#888";
      const body = document.createElement("span");
      body.className = "agenda-hidden-list-body";
      const name = document.createElement("span");
      name.className = "agenda-hidden-list-name";
      name.textContent = mark.dataset.name || "(untitled)";
      const meta = document.createElement("span");
      meta.className = "agenda-hidden-list-meta";
      meta.textContent = formatHiddenMeta(mark);
      body.appendChild(name);
      body.appendChild(meta);
      li.appendChild(dot);
      li.appendChild(body);
      li.addEventListener("click", (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        if (window.hideModal) window.hideModal("#agenda-hidden-list");
        // The details modal handler reads from the clicked element's
        // dataset. The mark carries the full data payload already, so
        // pass it directly — no need to find the original block.
        window.__openAgendaDetails?.(mark);
      });
      list.appendChild(li);
    });
  }

  function formatHiddenMeta(mark) {
    const start = Number(mark.dataset.startAt);
    if (!start) return mark.dataset.agendaName || "";
    const startMs = start * 1000;
    const d = new Date(startMs);
    const timeOpts = { hour: "numeric", minute: "2-digit" };
    const dayOpts = { weekday: "short", month: "short", day: "numeric" };
    const time = d.toLocaleTimeString(undefined, timeOpts);
    const day = d.toLocaleDateString(undefined, dayOpts);
    const agendaPart = mark.dataset.agendaName ? ` · ${mark.dataset.agendaName}` : "";
    return `${day} ${time}${agendaPart}`;
  }

  // ============================================================
  // WEEK VIEW
  // ============================================================
  function initWeekView(root) {
    const grid = $(".cal-week-grid", root);
    if (!grid) return;

    const dayStart = Number(grid.dataset.dayStartHour) || 3;
    setAnchoredToToday(root, dayStart);
    updateTodayBtnState(root, dayStart);

    if (!root.hasAttribute("data-cal-bound")) {
      root.setAttribute("data-cal-bound", "");
      bindWeekHandlers(root);
      bindCommonHandlers();
      scheduleDayRollover(root);
      installRefreshTriggers(root);
      installNavInterception(root);
      installCalJumpHook(root);
      startNowTick(root);
      bootAgendaStore(root);
    }

    buildWeekBlocks(root);
    // Defer scroll-to-now until after the layout has settled — measuring
    // before stylesheet apply gives stale column rects and the scroll
    // lands at the wrong spot.
    requestAnimationFrame(() => {
      updateStickyOffsets(root);
      scrollWeekToEarliestEvent(root);
    });
  }

  // ============================================================
  // AgendaStore boot — fires once per page load (initWeekView and
  // initMonthView both call this; the guard makes it idempotent).
  // Hydrates from localStorage immediately so the first paint comes
  // from cache, then kicks off the network bootstrap; subsequent
  // updates flow through the store subscriber below.
  // ============================================================
  let agendaStoreBooted = false;
  function bootAgendaStore(root) {
    if (agendaStoreBooted) return;
    if (!window.AgendaStore || !window.AgendaSync) return; // graceful no-op
    agendaStoreBooted = true;

    window.AgendaStore.hydrateFromLocal();

    // Re-render whenever the store changes — bootstrap, delta, optimistic
    // mutation, broadcast. Cheap because buildWeekBlocks re-hydrates seeds
    // from the store snapshot and reuses the same downstream layout pass.
    // No cold-start overlay — empty grid speaks for itself during the
    // sub-second window before bootstrap lands.
    window.AgendaStore.subscribe((reason) => {
      // `hydrate` is the initial localStorage replay — already painted by
      // the explicit buildWeekBlocks in initWeekView. Bootstrap/delta/page
      // arrive after with authoritative data; everything else is per-item
      // mutation that may have shifted what's visible.
      if (reason === "hydrate") return;
      const r = $(".agenda-cal-page");
      if (!r) return;
      if (r.classList.contains("agenda-cal-week-page")) buildWeekBlocks(r);
      else if (r.classList.contains("agenda-cal-month-page")) {
        // Seeds first — banner layout reads from the hidden seed container.
        rehydrateMonthSeedsFromStore(r);
        layoutMonthBanners(r);
        recountMonthOverflow(r);
      }
    });

    window.AgendaSync.subscribeMonitor();
    window.AgendaSync.installResumeTriggers();
    window.AgendaSync.boot();
  }

  // Pulls the visible week's events from AgendaStore and rewrites the
  // hidden seed DOM that the rest of this file consumes. Called from
  // buildWeekBlocks before the seeds-to-blocks pass runs. No-op if the
  // store isn't loaded — the legacy server-seeds path still works.
  function rehydrateSeedsFromStore(grid) {
    if (!window.AgendaSeedHydrator || !window.AgendaStore) return;
    const seedsContainer = $(".cal-week-seeds", grid);
    if (!seedsContainer) return;
    const weekStart = grid.dataset.weekStart;
    const weekEnd = grid.dataset.weekEnd;
    if (!weekStart || !weekEnd) return;
    // Lazy backfill: if the visible week is earlier than the store's
    // known floor, kick off the page request. The subscriber re-renders
    // when it lands.
    window.AgendaSync?.ensureRangeLoaded(weekStart, weekEnd);
    window.AgendaSeedHydrator.hydrateWeekSeeds(seedsContainer, weekStart, weekEnd);
  }

  // Width of the right-edge strip on each day column that's reserved for
  // drag-create even when an event sits on top of that slot. Lets the
  // user always start a new event on a given day without hunting for
  // empty vertical space.
  const RIGHT_GUTTER_PX = 12;
  // Symmetric reserved strip on the left edge of every day column. The
  // hidden-events gutter (and its colored marks) sit here so events never
  // overlap them, matching the right-edge drag-create reservation.
  const LEFT_GUTTER_PX = 8;
  // Drag thresholds. Raised from 6 → 8 for event-drag because trackpad
  // input has noticeable cursor jitter during a press-release; below
  // ~8px the user is almost certainly trying to click, not drag.
  const EVENT_DRAG_THRESHOLD_PX = 8;

  // Highlights every all-day cell between the start cell and the cell
  // currently under the cursor. Tolerant of either drag direction
  // (Mon → Wed or Wed → Mon, both should highlight Mon/Tue/Wed).
  function paintAllDayDragSelection(root, startCell, currentCell) {
    if (!root || !startCell || !currentCell) return;
    const cells = $$(".cal-week-allday-cell", root);
    const dates = cells.map((c) => c.dataset.date).sort();
    const startISO = startCell.dataset.date;
    const currentISO = currentCell.dataset.date;
    const lo = startISO <= currentISO ? startISO : currentISO;
    const hi = startISO <= currentISO ? currentISO : startISO;
    cells.forEach((c) => {
      const inRange = c.dataset.date >= lo && c.dataset.date <= hi;
      c.classList.toggle("is-drag-target", inRange);
    });
  }

  function clearAllDayDragSelection(root) {
    if (!root) return;
    $$(".cal-week-allday-cell.is-drag-target", root).forEach((c) => {
      c.classList.remove("is-drag-target");
    });
  }

  function startWeekCreateDrag(root, col, e) {
    e.preventDefault();
    const grid = $(".cal-week-grid", root);
    const snapPx = weekSnapPx(grid);
    const rect = col.getBoundingClientRect();
    const startPx = snapPxDown(e.clientY - rect.top, snapPx);
    weekDrag.col = col;
    weekDrag.startPx = startPx;
    weekDrag.sel = col.querySelector(".cal-week-drag-sel");
    weekDrag.moved = false;
    weekDrag.top = startPx;
    weekDrag.bottom = startPx + snapPx;
    weekDrag.ctx = { snapPx, pxPerMin: weekPxPerMin(grid), root };
  }

  function bindWeekHandlers(root) {
    // Clicks on the left-edge gutter marks → open a modal listing every
    // hidden event whose y-range overlaps the click point. Delegated so
    // it survives the rebuild that wipes the marks each pass.
    root.addEventListener("click", (e) => {
      const mark = e.target.closest(".cal-week-hidden-mark");
      if (!mark) return;
      e.preventDefault();
      e.stopPropagation();
      openHiddenListAt(mark, e);
    });

    // Drag-to-create and dbl-click on time grid — delegated to root.
    root.addEventListener("mousedown", (e) => {
      if (e.button !== 0) return;

      // ---- Right-edge gutter first: a 12px strip on the right of every
      // day column is reserved for drag-create regardless of what's
      // under the cursor (event, all-day chip, etc.). Lets the user
      // start a new event on a day even when the visible time slots
      // are wall-to-wall existing events.
      const colAtCursor = e.target.closest(".cal-week-column[data-date]");
      if (colAtCursor) {
        const colRect = colAtCursor.getBoundingClientRect();
        if (colRect.right - e.clientX <= RIGHT_GUTTER_PX) {
          startWeekCreateDrag(root, colAtCursor, e);
          return;
        }
      }

      // ---- event-drag init: mousedown on an existing event button ----
      // Don't `preventDefault` — the click event needs to fire for
      // agenda.js's `[data-open-details]` delegate.
      const eventBtn = e.target.closest(".cal-week-event");
      if (eventBtn) {
        if (eventBtn.hasAttribute("data-readonly")) {
          // Read-only: don't set up a real drag, but record the
          // start coords so mousemove can flip the cursor to
          // `not-allowed` if the user actually tries to drag.
          eventDragBlocked.btn = eventBtn;
          eventDragBlocked.startX = e.clientX;
          eventDragBlocked.startY = e.clientY;
          eventDragBlocked.moved = false;
          return;
        }
        const grid = $(".cal-week-grid", root);
        eventDrag.btn = eventBtn;
        eventDrag.startX = e.clientX;
        eventDrag.startY = e.clientY;
        eventDrag.moved = false;
        eventDrag.ctx = { grid, root, pxPerMin: weekPxPerMin(grid), snapPx: weekSnapPx(grid) };
        return;
      }

      if (e.target.closest(".cal-week-allday-chip")) return;

      // ---- all-day strip drag-to-create init ----
      // Mousedown on an all-day cell starts a date-range select. The
      // body-grid drag uses Y-pixel snapping inside one column; for the
      // all-day strip we instead track which CELL the cursor is over,
      // since the granularity is whole days.
      const alldayCell = e.target.closest(".cal-week-allday-cell");
      if (alldayCell) {
        e.preventDefault();
        allDayDrag.startCell = alldayCell;
        allDayDrag.currentCell = alldayCell;
        allDayDrag.moved = false;
        allDayDrag.root = root;
        // Highlight the start cell immediately so the user gets visual
        // feedback even before they move.
        paintAllDayDragSelection(root, alldayCell, alldayCell);
        return;
      }

      if (!colAtCursor) return;
      startWeekCreateDrag(root, colAtCursor, e);
    });

    root.addEventListener("dblclick", (e) => {
      if (e.target.closest(".cal-week-event")) return;
      const col = e.target.closest(".cal-week-column");
      const grid = $(".cal-week-grid", root);
      if (col && grid) {
        const pxPerMin = weekPxPerMin(grid);
        const snapPx = weekSnapPx(grid);
        const dayStart = Number(grid.dataset.dayStartHour) || 0;
        const rect = col.getBoundingClientRect();
        const startPx = snapPxDown(e.clientY - rect.top, snapPx);
        const startMinOffset = startPx / pxPerMin;
        const startClock = (dayStart * 60 + startMinOffset) % (24 * 60);
        const endClock = (startClock + 60) % (24 * 60);
        openAddModalForTime(col.dataset.date, startClock, endClock);
        return;
      }
      const cell = e.target.closest(".cal-week-allday-cell");
      if (cell) openAddModalForRange(cell.dataset.date, cell.dataset.date, true);
    });

    window.addEventListener("resize", () => {
      buildWeekBlocks(root);
      updateNowLine(root);
      updateStickyOffsets(root);
    });
  }

  function weekPxPerHour(grid) { return Number(grid.dataset.pxPerHour) || 56; }
  function weekPxPerMin(grid) { return weekPxPerHour(grid) / 60; }
  function weekSnapMin(grid) { return Number(grid.dataset.snapMin) || 15; }
  function weekSnapPx(grid) { return weekPxPerMin(grid) * weekSnapMin(grid); }
  function snapPxDown(px, snap) { return Math.floor(px / snap) * snap; }
  function snapPxUp(px, snap) { return Math.ceil(px / snap) * snap; }

  function buildWeekBlocks(root) {
    const grid = $(".cal-week-grid", root);
    if (!grid) return;
    // Rebuild the hidden seed DOM from AgendaStore so the rest of this
    // pass works against the cached set instead of whatever ERB last
    // emitted. No-op if the store isn't loaded yet (still-rendering
    // bootstrap, or page hasn't called bootAgendaStore).
    rehydrateSeedsFromStore(grid);

    const dayStart = Number(grid.dataset.dayStartHour) || 0;
    const pxPerMin = weekPxPerMin(grid);
    const snapPx = weekSnapPx(grid);
    const weekStart = grid.dataset.weekStart;
    const weekEnd = grid.dataset.weekEnd;

    // Wipe prior renders.
    $$(".cal-week-event", grid).forEach((e) => e.remove());
    $$(".cal-week-allday-chip", grid).forEach((e) => e.remove());

    const columns = {};
    $$(".cal-week-column", grid).forEach((c) => columns[c.dataset.date] = c);
    const alldayCells = {};
    $$(".cal-week-allday-cell", grid).forEach((c) => alldayCells[c.dataset.date] = c);
    const alldayWrap = $(".cal-week-allday-cells", grid);

    // Stable sort the seeds by (start_at, item_id) BEFORE iterating so
    // the rendered order is identical across page refreshes, monitor
    // broadcasts, and inline moves. Without an explicit tiebreaker the
    // hash-iteration order from Ruby + the lane-pack sort below leaves
    // events at the same time slot in undefined order — visually the
    // same events shuffled around between renders.
    const seeds = $$(".cal-week-seed", grid).sort((a, b) => {
      const sa = Number(a.dataset.startAt) || 0;
      const sb = Number(b.dataset.startAt) || 0;
      if (sa !== sb) return sa - sb;
      const ia = a.dataset.itemId || "";
      const ib = b.dataset.itemId || "";
      return ia < ib ? -1 : (ia > ib ? 1 : 0);
    });
    const timedByDate = {};
    const alldaySpecs = [];
    // Seeds the filter would have hidden — collected here so we can paint
    // gutter breadcrumbs WITHOUT participating in lane layout. That's the
    // whole point of hiding: free up horizontal room for the rest.
    const hiddenTimedSegs = [];

    seeds.forEach((seed) => {
      const d = seed.dataset;
      const startEpoch = Number(d.startAt);
      if (!startEpoch) return;
      // Agenda-toggle hides skip every render path — no chip, no gutter
      // breadcrumb, no lane slot. Only the explicit "Hide event" /
      // "Hide recurring" / "Hide name pattern" / "Declined" reasons
      // ride the gutter path below.
      if (window.__agendaSeedShouldRemove?.(seed)) return;
      const hiddenByFilter = !!window.__agendaSeedIsHidden?.(seed);
      if (d.allDay === "true") {
        if (!hiddenByFilter) alldaySpecs.push(specForAllDay(seed));
        return;
      }
      const endEpoch = Number(d.endAt) || (startEpoch + 3600);
      const segs = splitTimedIntoLogicalDays(startEpoch, endEpoch, dayStart);
      segs.forEach((seg) => {
        if (compareISO(seg.dateISO, weekStart) < 0) return;
        if (compareISO(seg.dateISO, weekEnd) > 0) return;
        const col = columns[seg.dateISO];
        if (!col) return;
        if (hiddenByFilter) {
          hiddenTimedSegs.push({ seed, seg, col });
          return;
        }
        // Pass `dayStart` explicitly — earlier versions tried to read
        // it via `node.closest(".cal-week-grid")` inside
        // `buildTimedEventNode`, but the node hasn't been appended to
        // the DOM yet so `closest()` returned null and the lookup
        // silently fell back to 0. That made every event's *label*
        // off by `dayStart` hours while the *position* (computed from
        // `seg.startMin` which already accounts for `dayStart`) stayed
        // correct — exactly the "4am Focus on the 7 AM gridline"
        // symptom in the screenshot.
        const ev = buildTimedEventNode(seed, seg, pxPerMin, dayStart);
        col.appendChild(ev.node);
        (timedByDate[seg.dateISO] = timedByDate[seg.dateISO] || []).push(ev);
      });
    });

    Object.keys(timedByDate).forEach((date) => layoutLanes(timedByDate[date]));
    layoutAllDayChips(alldaySpecs, alldayCells, alldayWrap);
    updateNowLine(root);
    // After lane widths are settled, hide the time on any tile whose
    // title can't fit. The title is the most important info on the
    // event — the time below should never be visible at its expense.
    requestAnimationFrame(() => hideTimeWhenTitleClips(grid));
    // Filter-hidden seeds left lane layout untouched (they never went
    // in), so visible blocks already claim the freed lanes. Now drop a
    // breadcrumb in the left gutter for each one.
    paintHiddenGutters(root, hiddenTimedSegs, pxPerMin);
    // Reapply the post-hoc filter pass owned by agenda.js — covers
    // the completed/tentative criteria that depend on classes the seeds
    // don't carry. Runs after gutter paint so the marks aren't touched.
    window.__applyAgendaVisibility?.();
  }

  // Returns one segment per logical day the event covers. Each segment is
  // {dateISO, startMin, endMin} where startMin and endMin are minutes from
  // the logical day-start (0..1440).
  function splitTimedIntoLogicalDays(startEpoch, endEpoch, dayStartHour) {
    const start = new Date(startEpoch * 1000);
    const end = new Date(endEpoch * 1000);
    const out = [];
    let segStart = start;
    let segDay = logicalDayStart(start, dayStartHour);
    // Guard: nonsensical (end <= start). Render as a 15-min slot so the
    // user still has something to click.
    if (end <= start) {
      const startMin = (start - segDay) / 60000;
      return [{ dateISO: formatDateISO(segDay), startMin, endMin: startMin + 15 }];
    }
    while (segStart < end) {
      const nextDayStart = new Date(segDay);
      nextDayStart.setDate(nextDayStart.getDate() + 1);
      const segEndTs = end < nextDayStart ? end : nextDayStart;
      const startMin = (segStart - segDay) / 60000;
      const endMin = (segEndTs - segDay) / 60000;
      out.push({ dateISO: formatDateISO(segDay), startMin, endMin });
      if (segEndTs >= end) break;
      segStart = nextDayStart;
      segDay = nextDayStart;
    }
    return out;
  }

  // Toggles `data-time-hidden` on tiles where the title would otherwise
  // be clipped. The CSS rule then `display: none`s the .cal-week-event-
  // time inside, freeing the entire content box for the title.
  function hideTimeWhenTitleClips(grid) {
    grid.querySelectorAll(".cal-week-event").forEach((tile) => {
      const name = tile.querySelector(".cal-week-event-name");
      const time = tile.querySelector(".cal-week-event-time");
      if (!name || !time) return;

      // Always reset first so a previously-hidden time reappears if the
      // tile is now big enough (e.g. user dragged to resize / widened
      // the column / lane count dropped).
      tile.removeAttribute("data-time-hidden");

      // Two-axis overflow check: vertical for stacked layout (.cal-week-
      // event-content is column-flex), horizontal for `.is-tiny` (row-
      // flex). The ±1 fudge avoids hiding on subpixel rounding.
      const overflowsVertically = name.scrollHeight > name.clientHeight + 1;
      const overflowsHorizontally = name.scrollWidth > name.clientWidth + 1;
      if (overflowsVertically || overflowsHorizontally) {
        tile.setAttribute("data-time-hidden", "");
        // Re-check after hiding — if the title now fits, great. If it
        // STILL overflows, leave the attribute so at least the time
        // isn't competing for the space.
      }
    });
  }

  function buildTimedEventNode(seed, seg, pxPerMin, dayStart) {
    const d = seed.dataset;
    const kind = d.kind || "event";
    // Tasks and triggers are POINT events — they fire at a time, they
    // don't span a duration. Render them as a thin 15-minute marker bar
    // regardless of the underlying end_at (which is mostly arbitrary for
    // these kinds). Visual = `<hr>`-style line of the agenda color.
    const isPoint = kind === "task" || kind === "trigger";

    const node = document.createElement("button");
    node.type = "button";
    node.className = "cal-week-event agenda-item-data";
    if (isPoint) node.classList.add("is-point");
    copyDataAttrs(seed, node);
    node.setAttribute("data-open-details", "");
    const color = d.agendaColor || d.color || "#888";
    node.style.setProperty("--agenda-color", color);

    const durationMin = isPoint ? 15 : Math.max(15, seg.endMin - seg.startMin);
    const continuedTopMaybe = (seg.startMin === 0) && !isPoint;
    // Travel-time band: faded extension above the solid event tile that
    // visualises "you need to leave this much earlier to arrive on time".
    // Suppressed for point events (tasks/triggers — no arrival semantics)
    // and continued-top segments (the event already started yesterday).
    // Clamped so the band can't push the tile above the column origin.
    const travelMinRaw = parseInt(d.travelMinutes, 10) || 0;
    const arriveEarlyMinRaw = parseInt(d.arriveEarlyMinutes, 10) || 0;
    // Chained events fill the visual GAP between the predecessor's end and
    // this event's start — even when the actual drive time is shorter.
    // For solo / chain-head events, the band is just arrive_early + travel
    // as it always was.
    const isChainCandidate = (d.travelFromKind === "event") && !isPoint && !continuedTopMaybe;
    const startEpochForBand = Number(d.startAt) || 0;
    const chainPrevEndEpoch = parseInt(d.chainPrevEndEpoch, 10) || 0;
    const rawChainGapMin = (isChainCandidate && chainPrevEndEpoch && startEpochForBand)
      ? Math.max(0, (startEpochForBand - chainPrevEndEpoch) / 60)
      : 0;
    // Only honor the chain-gap visualization when the predecessor sits
    // INSIDE this event's logical day. If the gap exceeds `seg.startMin`
    // (the minutes from the logical day-start to this event), the chain
    // crosses a day boundary — which usually means a move left stale
    // metadata behind ("Plunge?" got dragged to Sunday but still points
    // at Saturday's predecessor). Falling back to the standard
    // travel + arrive_early band here keeps the visual sane while the
    // server-side `AgendaTravelChainSyncWorker` rebuilds the chain in
    // the background.
    const isChained = isChainCandidate && rawChainGapMin > 0 && rawChainGapMin <= seg.startMin;
    const chainGapMin = isChained ? rawChainGapMin : 0;
    const travelMin = (isPoint || continuedTopMaybe)
      ? 0
      : (isChained
        ? chainGapMin
        : Math.min(travelMinRaw + arriveEarlyMinRaw, seg.startMin));
    // Tile box CONTAINS the band as its first flex child. Tile height
    // is band + true event duration; the content area (where the title
    // renders) is locked to exactly the event's pixel duration via
    // `--event-content-px`, so the title always gets the event's true
    // slot regardless of band size.
    //
    // Single `border-left` on the tile runs through both band and
    // content area — one strip, one element, no alignment to manage.
    // Point events (triggers + tasks) have no duration semantics, so we
    // give them exactly a 30-min visual slot — same vertical room as a
    // typical short event and consistent across columns. The previous
    // `Math.max(12, 15 * pxPerMin)` was rendering ~36-min worth of
    // pixels at the default 20px/hr.
    const eventHeight = isPoint
      ? 30 * pxPerMin
      : (durationMin * pxPerMin);
    // Post-travel band — driven by `to:<location>` in notes. Sits BELOW
    // the event tile (mirror of the pre-event band). Suppressed for point
    // events (no duration semantics) and multi-day top-continuation
    // segments (today's slice doesn't actually own the event's end).
    const postTravelMinRaw = parseInt(d.postTravelMinutes, 10) || 0;
    const postTravelMin = (isPoint || continuedTopMaybe) ? 0 : postTravelMinRaw;
    const bandPx = travelMin * pxPerMin;
    const postBandPx = postTravelMin * pxPerMin;
    const top = (seg.startMin - travelMin) * pxPerMin;
    const height = eventHeight + bandPx + postBandPx;
    node.style.top = `${top}px`;
    node.style.height = `${height}px`;
    node.style.left = "2px";
    node.style.right = "2px";
    node.style.setProperty("--event-content-px", `${eventHeight}px`);
    // Title gets a small top padding whenever the slot is at least 30
    // min — events, triggers, tasks alike. Roughly centers the title
    // in a 30-min block. Anything shorter drops it to zero so the
    // title gets every available pixel for legibility.
    const minSlotPx = 30 * pxPerMin;
    const titlePadTop = eventHeight >= minSlotPx ? 2 : 0;
    node.style.setProperty("--title-pad-top", `${titlePadTop}px`);
    if (travelMin > 0) node.classList.add("has-travel");
    // When THIS event is followed by another event in the chain, the
    // next event's incoming band sits directly below this tile. Square
    // off the bottom corners so the visual reads as a continuous block.
    if ((parseInt(d.chainSuccessorId, 10) || 0) > 0) node.classList.add("has-chain-successor");
    // When THIS event has a chained predecessor (its band's top edge
    // attaches to the previous event's squared bottom), square this
    // tile's TOP corners to meet the connection.
    if (isChained) node.classList.add("has-chain-predecessor");
    // Very small events: switch to a single-line row layout so a 1h
    // event reads cleanly as `Title` instead of trying to stack a title
    // and a time line into 18px of vertical space. Anything taller uses
    // the default top-to-bottom stack (title, then time directly below),
    // and overflow naturally clips the time when the container is small.
    if (isPoint || height < 30) node.classList.add("is-tiny");

    // Continuation hints — multi-day timed events split into one segment
    // per logical day; the joining corners get squared off so the
    // visual reads as "continues from / continues to".
    const startEpoch = Number(d.startAt);
    const endEpoch = Number(d.endAt) || startEpoch;
    const continuedTop = (seg.startMin === 0) && !isPoint;
    const continuedBottom = !isPoint
      && (seg.endMin >= 24 * 60 - 0.5)
      && (endEpoch * 1000 > new Date(startEpoch * 1000).getTime() + (24 * 60 - seg.startMin) * 60_000 - 60_000);
    if (continuedTop) node.classList.add("is-continued-top");
    if (continuedBottom) node.classList.add("is-continued-bottom");

    // Travel-time band: prepended as the first flex child so the content
    // wrapper below gets pushed down by the band's reserved space.
    if (travelMin > 0) {
      const travelBand = document.createElement("div");
      travelBand.className = "cal-week-event-travel";
      if (isChained) travelBand.classList.add("is-chained");
      // Flex child — reserve the band's vertical slice via inline height.
      travelBand.style.height = `${bandPx}px`;

      // Multi-stop visualization: alternating-stripe drive segments + solid
      // dwell bars at each waypoint. Renders ONLY when there are ≥2 legs
      // (waypoints present) — solo drives stay as a single stripe band.
      const beforeLegs = parseLegsAttr(d.beforeLegs);
      if (beforeLegs && beforeLegs.length > 1 && travelMinRaw > 0) {
        appendLegBars(travelBand, beforeLegs, travelMinRaw * 60, bandPx);
      }
      // Always the condensed `[clock] Nm + [car] Mm` form. Hide the label
      // entirely on tiny bands (<6px) — stripes only, no text.
      // A second, summed `[clock] (N+M)m` label rides along — hidden by
      // default, swapped in via CSS when the event tile is narrow (lane
      // layout adds .is-narrow). Keeps the label legible when the column
      // shrinks under overlap.
      if (bandPx >= 6) {
        const drivePart = travelMinRaw > 0 ? travelMinRaw : 0;
        const earlyPart = arriveEarlyMinRaw > 0 ? arriveEarlyMinRaw : 0;
        const label = document.createElement("span");
        label.className = "cal-week-event-travel-label is-compact";
        const startEpochRaw = parseInt(d.startAt, 10) || 0;
        if (startEpochRaw > 0 && (earlyPart > 0 || drivePart > 0)) {
          const leaveEpoch = startEpochRaw - (earlyPart + drivePart) * 60;
          const leave = document.createElement("span");
          leave.className = "cal-week-event-travel-leave";
          // ↳ for chained legs (travel between two events on the calendar),
          // → for the default home-origin leg. Time math is identical.
          leave.textContent = `${isChained ? "↳" : "→"}${fmtCalTime(leaveEpoch)}`;
          label.appendChild(leave);
        }
        const fmtMin = window.AgendaItemRenderer?.fmtMinutes || ((n) => `${n}m`);
        if (earlyPart > 0) {
          label.appendChild(Object.assign(document.createElement("i"), { className: "fa fa-clock-o" }));
          label.appendChild(document.createTextNode(fmtMin(earlyPart)));
        }
        if (drivePart > 0) {
          label.appendChild(Object.assign(document.createElement("i"), { className: "fa fa-car" }));
          label.appendChild(document.createTextNode(fmtMin(drivePart)));
        }
        travelBand.appendChild(label);

        const sumPart = earlyPart + drivePart;
        if (sumPart > 0) {
          const narrowLabel = document.createElement("span");
          narrowLabel.className = "cal-week-event-travel-label is-narrow-fallback";
          narrowLabel.appendChild(document.createTextNode(fmtMin(sumPart)));
          narrowLabel.appendChild(Object.assign(document.createElement("i"), { className: "fa fa-clock-o" }));
          travelBand.appendChild(narrowLabel);
        }
      }
      node.appendChild(travelBand);
    }

    // Content wrapper: this is what gets the right-edge mask in SCSS.
    // Putting the mask on a wrapper that lives INSIDE the card lets the
    // card's background, border, and rounded corners render unmasked
    // (so the tile reads as a solid block) while still fading the text
    // content at the tile's right edge.
    const content = document.createElement("div");
    content.className = "cal-week-event-content";

    // Title first, time second — Mac Calendar order.
    const nameSpan = document.createElement("span");
    nameSpan.className = "cal-week-event-name";
    nameSpan.textContent = d.name || "";
    content.appendChild(nameSpan);

    // Time label uses the dayStart passed from buildWeekBlocks (not a
    // DOM lookup against an un-attached node).
    const startClock = (dayStart * 60 + seg.startMin) % (24 * 60);
    const endClock = (dayStart * 60 + seg.endMin) % (24 * 60);
    const hasRange = !isPoint && endEpoch && endEpoch !== startEpoch;
    const timeSpan = document.createElement("span");
    timeSpan.className = "cal-week-event-time";
    timeSpan.textContent = continuedTop
      ? `until ${formatLabelTime(endClock)}`
      : hasRange
        ? `${formatLabelTime(startClock)} – ${formatLabelTime(endClock)}`
        : formatLabelTime(startClock);
    content.appendChild(timeSpan);

    node.appendChild(content);

    // Post-travel band — appended LAST so it occupies the bottom flex
    // slot of the tile (`event-content-px` locks the middle slot to the
    // event's true duration, so the band naturally fills `postBandPx`
    // below it). Format mirrors the pre-event band: car icon + minutes,
    // then `→arrive-time` instead of `leave-time→`.
    if (postTravelMin > 0) {
      const postBand = document.createElement("div");
      postBand.className = "cal-week-event-travel is-post";
      postBand.style.height = `${postBandPx}px`;
      node.classList.add("has-post-travel");

      const afterLegs = parseLegsAttr(d.afterLegs);
      if (afterLegs && afterLegs.length > 1) {
        appendLegBars(postBand, afterLegs, postTravelMin * 60, postBandPx);
      }
      if (postBandPx >= 6) {
        const fmtMin = window.AgendaItemRenderer?.fmtMinutes || ((n) => `${n}m`);
        const label = document.createElement("span");
        label.className = "cal-week-event-travel-label is-compact";
        label.appendChild(Object.assign(document.createElement("i"), { className: "fa fa-car" }));
        label.appendChild(document.createTextNode(fmtMin(postTravelMin)));
        const postArriveEpoch = parseInt(d.postArriveAtEpoch, 10) || 0;
        if (postArriveEpoch > 0) {
          const arrive = document.createElement("span");
          arrive.className = "cal-week-event-travel-leave";
          arrive.textContent = `→${fmtCalTime(postArriveEpoch)}`;
          label.appendChild(arrive);
        }
        postBand.appendChild(label);

        const narrowLabel = document.createElement("span");
        narrowLabel.className = "cal-week-event-travel-label is-narrow-fallback";
        narrowLabel.appendChild(document.createTextNode(fmtMin(postTravelMin)));
        narrowLabel.appendChild(Object.assign(document.createElement("i"), { className: "fa fa-car" }));
        postBand.appendChild(narrowLabel);
      }
      node.appendChild(postBand);
    }

    // For overlap-layout:
    //   * Travel band extends the EFFECTIVE start backward by travelMin
    //     so a concurrent event in that window goes into a different
    //     lane instead of visually colliding with the band.
    //   * Post-travel band extends the EFFECTIVE end forward by
    //     postTravelMin so an event scheduled in the outgoing window also
    //     lands in a separate lane.
    //   * Point events (triggers/tasks) get rendered with a 12-px MINIMUM
    //     height — at the default 20px/hr that's ~36 visual minutes, well
    //     past the 15-min "logical slot". If we declare a 15-min footprint
    //     for lanes, a next-door event whose travel band starts ~7:15am
    //     after a 7am trigger is technically "adjacent" but visually
    //     plows through the trigger tile. Use whichever is larger of the
    //     logical slot and the actual rendered slot so lane detection
    //     matches what the user sees.
    const effectiveStartMin = seg.startMin - travelMin;
    const pointSlotMin = Math.max(15, eventHeight / pxPerMin);
    const effectiveEndMin = isPoint ? seg.startMin + pointSlotMin : seg.endMin + postTravelMin;
    return { node, dateISO: seg.dateISO, startMin: effectiveStartMin, endMin: effectiveEndMin };
  }

  function specForAllDay(seed) {
    const d = seed.dataset;
    const startEpoch = Number(d.startAt);
    const start = new Date(startEpoch * 1000);
    const endEpoch = Number(d.endDate) || startEpoch;
    const end = new Date(endEpoch * 1000);
    const node = document.createElement("button");
    node.type = "button";
    node.className = "cal-week-allday-chip agenda-item-data";
    copyDataAttrs(seed, node);
    node.setAttribute("data-open-details", "");
    node.style.setProperty("--agenda-color", d.agendaColor || "#888");
    node.textContent = d.name || "";
    return { node, startDate: formatDateISO(start), endDate: formatDateISO(end) };
  }

  // Per-cluster lane layout with a stable tiebreaker on item-id so
  // co-incident events render in the same order across refreshes.
  // Also reserves a right-edge gutter (RIGHT_GUTTER_PX) on the rightmost
  // lane of each cluster so the user can always click-drag-create on
  // the right side of a day, even when events sit at that time.
  function layoutLanes(events) {
    events.sort((a, b) => {
      if (a.startMin !== b.startMin) return a.startMin - b.startMin;
      if (a.endMin !== b.endMin) return a.endMin - b.endMin;
      const ia = a.node.dataset.itemId || "";
      const ib = b.node.dataset.itemId || "";
      return ia < ib ? -1 : (ia > ib ? 1 : 0);
    });
    const clusters = [];
    let cur = null;
    let curMaxEnd = -Infinity;
    events.forEach((ev) => {
      if (cur && ev.startMin < curMaxEnd) {
        cur.push(ev);
        curMaxEnd = Math.max(curMaxEnd, ev.endMin);
      } else {
        cur = [ev];
        curMaxEnd = ev.endMin;
        clusters.push(cur);
      }
    });
    clusters.forEach((cluster) => {
      const lanes = [];
      cluster.forEach((ev) => {
        let placed = false;
        for (let i = 0; i < lanes.length; i++) {
          if (lanes[i] <= ev.startMin) {
            lanes[i] = ev.endMin;
            ev.lane = i;
            placed = true;
            break;
          }
        }
        if (!placed) {
          ev.lane = lanes.length;
          lanes.push(ev.endMin);
        }
      });
      const total = Math.max(1, lanes.length);
      cluster.forEach((ev) => {
        const isLeftmost = ev.lane === 0;
        const isRightmost = ev.lane === total - 1;
        // Rightmost-lane events leave the right gutter clear; leftmost
        // events leave the new left-edge hidden-gutter clear. Everyone
        // else uses a 2px lane gap. `leftPadExtra` is just the extra px
        // beyond the always-applied 1px lane gap.
        const rightInset = isRightmost ? RIGHT_GUTTER_PX + 2 : 2;
        const leftPadExtra = isLeftmost ? LEFT_GUTTER_PX : 0;
        const widthPct = 100 / total;
        const leftPct = ev.lane * widthPct;
        ev.node.style.left = `calc(${leftPct}% + ${1 + leftPadExtra}px)`;
        ev.node.style.width = `calc(${widthPct}% - ${rightInset + leftPadExtra}px)`;
        ev.node.style.right = "auto";
        ev.node.classList.toggle("is-narrow", total > 1);
      });
    });
  }

  function layoutAllDayChips(specs, alldayCells, alldayWrap) {
    if (!alldayWrap) return;
    if (specs.length === 0) {
      alldayWrap.parentElement.style.minHeight = "";
      return;
    }
    specs.sort((a, b) => compareISO(a.startDate, b.startDate));
    const rows = [];
    specs.forEach((s) => {
      let placed = false;
      for (let i = 0; i < rows.length; i++) {
        if (compareISO(rows[i], s.startDate) < 0) {
          rows[i] = s.endDate;
          s.row = i;
          placed = true;
          break;
        }
      }
      if (!placed) {
        s.row = rows.length;
        rows.push(s.endDate);
      }
    });

    const wrapRect = alldayWrap.getBoundingClientRect();
    const rowHeight = 20;
    const rowGap = 2;
    // Per-side inset bites px out of each chip's column-edge so two
    // back-to-back chips (one ending Mon, the next starting Tue) show
    // a visible gap instead of merging into one continuous blue bar.
    // 6px each side → 12px gap. The chip CSS also adds a chrome-tinted
    // outline so each chip carries its own crisp edge even when adjacent
    // chips share an agenda color and would otherwise blur together.
    const sideInset = 6;
    specs.forEach((s) => {
      // Bail if neither end of the chip's date range overlaps the
      // visible week. Without this, a stray item (e.g. an all-day event
      // whose exclusive next-day-midnight falsely passed the range
      // filter) would render against the first cell as a fallback,
      // painting on the wrong day. The store's `inclusiveEnd` fix
      // upstream should keep this list clean; this is belt-and-braces.
      const visibleDates = Object.keys(alldayCells).sort();
      const firstISO = visibleDates[0];
      const lastISO = visibleDates[visibleDates.length - 1];
      if (!firstISO || compareISO(s.endDate, firstISO) < 0) return;
      if (!lastISO || compareISO(s.startDate, lastISO) > 0) return;
      // Clamp the visible span to what this week actually shows so
      // multi-week events render only their in-week segment.
      const segStart = compareISO(s.startDate, firstISO) < 0 ? firstISO : s.startDate;
      const segEnd = compareISO(s.endDate, lastISO) > 0 ? lastISO : s.endDate;
      const startCell = alldayCells[segStart];
      const endCell = alldayCells[segEnd] || startCell;
      if (!startCell) return;
      // Mark the chip when its real span extends past the visible week
      // on either side so the CSS can drop the rounded corner and make
      // it clear the event continues. Mirrors month-banner styling.
      const continuedLeft = compareISO(s.startDate, firstISO) < 0;
      const continuedRight = compareISO(s.endDate, lastISO) > 0;
      s.node.classList.toggle("is-continued-left", continuedLeft);
      s.node.classList.toggle("is-continued-right", continuedRight);
      const sRect = startCell.getBoundingClientRect();
      const eRect = endCell.getBoundingClientRect();
      const left = sRect.left - wrapRect.left;
      const right = eRect.right - wrapRect.left;
      s.node.style.position = "absolute";
      s.node.style.left = `${left + sideInset}px`;
      s.node.style.width = `${right - left - (sideInset * 2)}px`;
      s.node.style.top = `${2 + s.row * (rowHeight + rowGap)}px`;
      s.node.style.height = `${rowHeight - 2}px`;
      alldayWrap.appendChild(s.node);
    });
    alldayWrap.parentElement.style.minHeight = `${4 + rows.length * (rowHeight + rowGap)}px`;
  }

  // ---- current-time line + gutter chip ----
  function updateNowLine(root) {
    const grid = $(".cal-week-grid", root);
    if (!grid) return;
    const dayStart = Number(grid.dataset.dayStartHour) || 0;
    const pxPerMin = weekPxPerMin(grid);
    const nowLine = $(".cal-week-now-line", grid);
    const nowChip = $(".cal-week-now-chip", grid);
    if (!nowLine) return;
    const todayISO = logicalDateISO(new Date(), dayStart);
    const todayCol = $(`.cal-week-column[data-date="${todayISO}"]`, grid);
    if (!todayCol) {
      nowLine.classList.add("hidden");
      nowChip?.classList.add("hidden");
      return;
    }
    const now = new Date();
    const dayBoundary = logicalDayStart(now, dayStart);
    const offsetMin = (now - dayBoundary) / 60000;
    const top = offsetMin * pxPerMin;
    const parent = nowLine.parentElement;
    const parentRect = parent.getBoundingClientRect();
    const colRect = todayCol.getBoundingClientRect();
    nowLine.style.top = `${top}px`;
    nowLine.style.left = `${colRect.left - parentRect.left}px`;
    nowLine.style.width = `${colRect.width}px`;
    nowLine.classList.remove("hidden");

    // Gutter chip — same Y as the now-line; shows wall-clock time.
    if (nowChip) {
      nowChip.style.top = `${top}px`;
      const timeEl = nowChip.querySelector(".cal-week-now-time");
      if (timeEl) {
        let h = now.getHours();
        const m = now.getMinutes();
        const ampm = h >= 12 ? "PM" : "AM";
        h = h % 12 || 12;
        timeEl.textContent = `${h}:${String(m).padStart(2, "0")} ${ampm}`;
      }
      nowChip.classList.remove("hidden");
    }
  }

  // Display-only minute tick. Distinct from any data-sync — that flows
  // through the existing agenda.js Monitor subscription.
  let nowTickInstalled = false;
  function startNowTick(root) {
    if (nowTickInstalled) return;
    nowTickInstalled = true;
    setInterval(() => {
      const r = $(".agenda-cal-week-page");
      if (r) updateNowLine(r);
    }, 60_000);
  }

  // Scrolls so the row one hour before the visible week's earliest timed
  // event sits at the top of the body, clamped to the bottom of the
  // grid. Prioritizes showing the later part of the day, which matches
  // how the user mentally weights the schedule. Falls back to bottom
  // when there are no timed events.
  function scrollWeekToEarliestEvent(root) {
    const grid = $(".cal-week-grid", root);
    const body = $(".cal-week-body", root);
    if (!grid || !body) return;
    const dayStart = Number(grid.dataset.dayStartHour) || 0;
    const pxPerHour = weekPxPerHour(grid);
    // Header + all-day are sticky inside the grid; the body content
    // starts past them. Use the body's own offsetTop (within the grid)
    // as the base so scrolling lands at the right hour regardless of
    // sticky-header height variations.
    const bodyOffsetTop = body.offsetTop;
    const maxScroll = Math.max(0, grid.scrollHeight - grid.clientHeight);

    // All-day items live in the sticky band above the body so they're
    // excluded from "earliest" — they have no Y position in the grid.
    const seeds = grid.querySelectorAll(".cal-week-seed");
    let earliestOffsetMin = Infinity;
    seeds.forEach((seed) => {
      if (seed.dataset.allDay === "true") return;
      const startAt = Number(seed.dataset.startAt);
      if (!startAt) return;
      const start = new Date(startAt * 1000);
      const offsetMin = (start - logicalDayStart(start, dayStart)) / 60000;
      if (offsetMin < earliestOffsetMin) earliestOffsetMin = offsetMin;
    });

    const desired = (
      earliestOffsetMin === Infinity
        ? maxScroll
        : bodyOffsetTop + (earliestOffsetMin / 60 - 1) * pxPerHour
    );
    grid.scrollTop = Math.max(0, Math.min(desired, maxScroll));
  }

  // Sets a CSS variable so the all-day band's `position: sticky; top: …`
  // can offset by the actual measured header height (changes with font
  // scaling, line-clamping at narrow widths, etc.).
  function updateStickyOffsets(root) {
    const header = $(".cal-week-header", root);
    if (!header) return;
    const h = header.getBoundingClientRect().height;
    if (h > 0) root.style.setProperty("--cal-week-header-offset", `${Math.round(h)}px`);
  }

  // Document-level Escape handler. Priority:
  //   1) If a drag is in progress, cancel it (revert in place).
  //   2) Otherwise close the topmost shown modal.
  document.addEventListener("keydown", (e) => {
    if (e.key !== "Escape") return;
    if (eventDrag.btn && eventDrag.moved) {
      e.preventDefault();
      cancelEventDrag();
      return;
    }
    if (eventDragBlocked.moved) {
      e.preventDefault();
      clearBlockedDrag();
      return;
    }
    const shown = Array.from(document.querySelectorAll(".modal.shown"));
    if (shown.length === 0) return;
    e.preventDefault();
    const top = shown[shown.length - 1];
    if (top.id && window.hideModal) window.hideModal(`#${top.id}`);
  });

  // ============================================================
  // CLIENT-SIDE NAVIGATION
  // ============================================================
  // Client-side navigation. Prev/Next/Today/Month↔Week/Today-pill
  // clicks NEVER hit the server for data — AgendaStore already knows
  // every event and schedule in the cache, including future phantoms
  // built locally from the recurrence rules. We just:
  //   1. pushState the URL so refresh/share/bookmark reflect the
  //      viewing date.
  //   2. Update the grid's `data-week-start` / `data-week-end` and the
  //      per-day-column `data-date` + is-today markers.
  //   3. Re-paint toolbar title.
  //   4. Re-run buildWeekBlocks, which calls rehydrateSeedsFromStore
  //      and lays out events for the new window.
  //
  // Cross-view nav (week ↔ month) still hits the server (the month
  // shell has different DOM scaffolding). Once that view is also
  // converted to AgendaStore, this can promote to pure client-side
  // too.
  function navigateClientSide(url) {
    const root = $(".agenda-cal-page");
    if (!root) { window.location.assign(url); return; }

    const isWeekTarget = url.pathname === "/agenda/grid";
    const isMonthTarget = url.pathname === "/agenda/month";
    const onWeek = root.classList.contains("agenda-cal-week-page");
    const onMonth = root.classList.contains("agenda-cal-month-page");

    // Same-view nav (the common case): pure client-side state change.
    if (isWeekTarget && onWeek) {
      history.pushState(null, "", url.href);
      const dateParam = url.searchParams.get("date");
      const targetISO = dateParam || logicalDateISO(new Date(), 3);
      renderWeekFor(root, targetISO);
      return;
    }
    if (isMonthTarget && onMonth) {
      history.pushState(null, "", url.href);
      const monthParam = url.searchParams.get("month"); // "YYYY-MM" or null
      const targetMonthISO = monthParam || todayMonthISO();
      renderMonthFor(root, targetMonthISO);
      return;
    }

    // Cross-view (or unknown target): fall back to a real navigation.
    window.location.assign(url.href);
  }

  // Re-render the week view for the visible window that contains
  // `dateISO`. Updates per-day data attributes, the toolbar title, the
  // current-time markers, and finally repaints events from the store.
  function renderWeekFor(root, dateISO) {
    const grid = $(".cal-week-grid", root);
    if (!grid) return;
    const weekStartISO = mondayOf(dateISO);
    const weekEndISO = addDaysISO(weekStartISO, 6);
    grid.dataset.weekStart = weekStartISO;
    grid.dataset.weekEnd = weekEndISO;
    root.dataset.weekStart = weekStartISO;
    root.dataset.weekEnd = weekEndISO;
    root.dataset.currentDate = dateISO;

    const todayISO = logicalDateISO(new Date(), Number(grid.dataset.dayStartHour) || 3);

    // Header day cells: numbers + today highlight.
    const headerCells = $$(".cal-week-header-day", root);
    headerCells.forEach((cell, idx) => {
      const d = addDaysISO(weekStartISO, idx);
      cell.dataset.date = d;
      cell.classList.toggle("is-today", d === todayISO);
      const dow = cell.querySelector(".cal-week-header-dow");
      const num = cell.querySelector(".cal-week-header-day-num");
      const dt = parseISODate(d);
      if (dow) dow.textContent = dt.toLocaleDateString(undefined, { weekday: "short" });
      if (num) num.textContent = String(dt.getDate());
    });

    // All-day cells.
    $$(".cal-week-allday-cell", root).forEach((cell, idx) => {
      const d = addDaysISO(weekStartISO, idx);
      cell.dataset.date = d;
      cell.dataset.weekday = String(idx);
      cell.classList.toggle("is-today", d === todayISO);
    });

    // Day columns.
    $$(".cal-week-column", root).forEach((col, idx) => {
      const d = addDaysISO(weekStartISO, idx);
      col.dataset.date = d;
      col.dataset.weekday = String(idx);
      col.classList.toggle("is-today", d === todayISO);
    });

    // Toolbar title — "January 2026". Mirrors the server-side logic
    // (perceived-today's month if in-week, else week's first day).
    const titleEl = $(".cal-toolbar-title", root);
    if (titleEl) {
      const focusISO = (todayISO >= weekStartISO && todayISO <= weekEndISO) ? todayISO : weekStartISO;
      const focusDt = parseISODate(focusISO);
      titleEl.textContent = focusDt.toLocaleDateString(undefined, { month: "long", year: "numeric" });
    }

    // Update prev/next/today links so click → next-week URL stays
    // accurate after a client-side jump.
    const prevLink = $(".cal-toolbar-nav a.prev", root);
    const nextLink = $(".cal-toolbar-nav a.next", root);
    if (prevLink) prevLink.href = `/agenda/grid?date=${addDaysISO(weekStartISO, -7)}`;
    if (nextLink) nextLink.href = `/agenda/grid?date=${addDaysISO(weekStartISO, 7)}`;

    buildWeekBlocks(root);
    updateNowLine(root);
    // After an in-page jump (prev/next/Today), update the Today-pill
    // state + the anchored flag so a future midnight rollover behaves as
    // if the page were freshly loaded onto whatever date the user landed
    // on. Today-button click → anchored=true → snap back next midnight.
    // Next-week click → anchored=false → stay put.
    setAnchoredToToday(root, Number(grid.dataset.dayStartHour) || 3);
    updateTodayBtnState(root, Number(grid.dataset.dayStartHour) || 3);
  }

  // Build a `.cal-month-block` DOM node for `monthISO` ("YYYY-MM").
  // No insertion — caller appends/prepends as needed. Reused by both
  // the single-month reset path (`renderMonthFor`) and the mobile
  // infinite-scroll prepender/appender.
  function buildMonthBlockNode(monthISO) {
    const [yStr, mStr] = monthISO.split("-");
    const year = parseInt(yStr, 10);
    const monthIdx = parseInt(mStr, 10) - 1;
    if (!Number.isFinite(year) || monthIdx < 0 || monthIdx > 11) return null;

    const monthStartDt = new Date(year, monthIdx, 1);
    const monthEndDt = new Date(year, monthIdx + 1, 0); // last day
    const firstVisibleISO = mondayOf(toISO(monthStartDt));
    const lastVisibleISO = sundayOf(toISO(monthEndDt));
    const todayISO = toISO(new Date());

    const block = document.createElement("div");
    block.className = "cal-month-block";
    block.dataset.monthBlock = "";
    block.dataset.monthIso = monthISO;
    block.dataset.blockStart = firstVisibleISO;
    block.dataset.blockEnd = lastVisibleISO;

    const blockHeader = document.createElement("div");
    blockHeader.className = "cal-month-block-header";
    blockHeader.setAttribute("data-block-header", "");
    blockHeader.setAttribute("aria-hidden", "true");
    blockHeader.textContent = monthStartDt.toLocaleDateString(undefined, { month: "long", year: "numeric" });
    block.appendChild(blockHeader);

    let cursorISO = firstVisibleISO;
    while (cursorISO <= lastVisibleISO) {
      const weekEndISO = addDaysISO(cursorISO, 6);
      const row = document.createElement("div");
      row.className = "cal-month-row";
      row.dataset.rowStart = cursorISO;
      row.dataset.rowEnd = weekEndISO;

      const banners = document.createElement("div");
      banners.className = "cal-month-row-banners";
      banners.setAttribute("data-row-banners", "");
      banners.setAttribute("aria-hidden", "true");
      row.appendChild(banners);

      // Tracks whether this row contains the 1st of THIS block's month —
      // drives the mobile divider + inline label (no-op on desktop).
      // Mirrors the ERB's `has_month_start` flag.
      let hasMonthStart = false;

      for (let offset = 0; offset < 7; offset++) {
        const dayISO = addDaysISO(cursorISO, offset);
        const dt = parseISODate(dayISO);
        const inMonth = dt.getMonth() === monthIdx;
        const isToday = dayISO === todayISO;
        const cell = document.createElement("div");
        cell.className = `cal-month-cell${isToday ? " is-today" : ""}${inMonth ? "" : " other-month"}`;
        cell.dataset.date = dayISO;
        cell.dataset.weekday = String(dt.getDay());
        cell.setAttribute("role", "button");
        cell.setAttribute("tabindex", "0");

        const head = document.createElement("div");
        head.className = "cal-month-cell-head";
        const isFirstOfMonth = dt.getDate() === 1;
        if (isFirstOfMonth) {
          const monthLabel = document.createElement("span");
          monthLabel.className = "cal-month-cell-month-label";
          monthLabel.setAttribute("aria-hidden", "true");
          monthLabel.textContent = dt.toLocaleDateString(undefined, { month: "short" });
          head.appendChild(monthLabel);
          if (inMonth) hasMonthStart = true;
        }
        const num = document.createElement("span");
        num.className = "cal-month-day-num";
        num.textContent = String(dt.getDate());
        head.appendChild(num);
        cell.appendChild(head);

        const items = document.createElement("div");
        items.className = "cal-month-cell-items";
        items.setAttribute("data-items-container", "");
        cell.appendChild(items);

        const overflow = document.createElement("span");
        overflow.className = "cal-month-overflow hidden";
        overflow.setAttribute("aria-hidden", "true");
        cell.appendChild(overflow);

        row.appendChild(cell);
      }

      if (hasMonthStart) row.classList.add("has-month-start");
      block.appendChild(row);
      cursorISO = addDaysISO(weekEndISO, 1);
    }

    return block;
  }

  // Re-render the month view for a new target month, ENTIRELY
  // client-side. Mirrors `renderWeekFor`: rebuild the grid DOM, update
  // toolbar + nav hrefs, then run the same hydration + layout passes
  // `initMonthView` runs on first mount.
  //
  // `monthISO` is "YYYY-MM". The visible range extends from the Monday
  // of the week containing day 1 through the Sunday of the week
  // containing the last day — same convention as
  // AgendasController#cal_month.
  function renderMonthFor(root, monthISO) {
    const grid = $(".cal-month-grid", root);
    if (!grid) return;
    const stack = grid.querySelector("[data-month-stack]");
    const block = buildMonthBlockNode(monthISO);
    if (!stack || !block) return;
    const firstVisibleISO = block.dataset.blockStart;
    const lastVisibleISO = block.dataset.blockEnd;

    // Toolbar title — "<Mon> <Year>". Short form (matches ERB
    // server-render + the mobile scroll-driven title tracker) so a
    // long month name like "September" doesn't squeeze the right-side
    // toolbar controls on narrow viewports.
    const titleEl = $(".cal-toolbar-title", root);
    if (titleEl) {
      const dt = parseISODate(`${monthISO}-01`);
      titleEl.textContent = dt.toLocaleDateString(undefined, { month: "short", year: "numeric" });
    }

    // Prev/next/Today links. The toolbar's "Today" link is a static
    // `/agenda/month` href that's already correct; we only need to
    // refresh prev/next.
    const prevMonth = addMonthsISO(monthISO, -1);
    const nextMonth = addMonthsISO(monthISO, +1);
    const prevLink = $(".cal-toolbar-nav a.prev", root);
    const nextLink = $(".cal-toolbar-nav a.next", root);
    if (prevLink) prevLink.href = `/agenda/month?month=${prevMonth}`;
    if (nextLink) nextLink.href = `/agenda/month?month=${nextMonth}`;

    // Update the grid's window markers — agenda_cal + month_view both
    // read these to drive their item-range queries against AgendaStore.
    grid.dataset.monthStart = firstVisibleISO;
    grid.dataset.monthEnd = lastVisibleISO;
    root.dataset.currentDate = `${monthISO}-01`;

    // Replace the weekday header row text (still 7 columns starting
    // Monday). Keeps existing DOM nodes — just rewrites textContent so
    // any locale-changes flow through.
    const weekdayHeads = $$(".cal-month-weekday-head", grid);
    weekdayHeads.forEach((cell, idx) => {
      const dt = parseISODate(addDaysISO(firstVisibleISO, idx));
      cell.textContent = dt.toLocaleDateString(undefined, { weekday: "short" });
    });

    // Tear down any existing month blocks; insert the freshly-built one
    // between the up/down loader sentinels (which stay put for the
    // mobile infinite-scroll observer to re-anchor to).
    $$("[data-month-block]", stack).forEach((b) => b.remove());
    mobileInfinite.observed = false; // force re-bind after DOM swap
    const downLoader = stack.querySelector('[data-month-loader="down"]');
    if (downLoader) stack.insertBefore(block, downLoader);
    else stack.appendChild(block);

    // Ensure the store has data for the new window, then notify
    // subscribers so month_view + agenda_cal both repaint against the
    // freshly-rebuilt DOM.
    window.AgendaSync?.ensureRangeLoaded(firstVisibleISO, lastVisibleISO);
    rehydrateMonthSeedsFromStore(root);
    layoutMonthBanners(root);
    recountMonthOverflow(root);
    // Re-fire a notify so month_view.js (which lives in its own module
    // and subscribes to the store) re-runs its per-cell render against
    // the new cell DOM. Without this the cells stay empty until the
    // next sync.
    window.AgendaStore?.notify?.("page");
    // See renderWeekFor's tail: keep the anchored-to-today flag in sync
    // with whatever the user just jumped to.
    setAnchoredToToday(root, 3);
    updateTodayBtnState(root, 3);

    // Mobile: re-activate the infinite-scroll layer around the new
    // center month (adds 2 prior + 2 next blocks, rebinds observers).
    activateMobileMonthInfinite(root);
  }

  // ============================================================
  // MOBILE MONTH VIEW (iOS-style continuous + lazy forward scroll)
  // ============================================================
  // Below the mobile breakpoint, the month view is a continuous
  // vertical stack of months. Activate seeds just three blocks:
  //   - 1 prior month  (one month of back-context)
  //   - the center     (server-rendered current month)
  //   - 1 next month   (smooths the first forward-scroll)
  // Forward scroll is infinite — the down-loader appends one month
  // at a time as the user approaches the bottom. Back-scroll is NOT
  // dynamic — the up-loader has been removed. The user explicitly
  // accepted "prior month + current is sufficient" because every
  // dynamic-prepend implementation had subtle jump-to-month bugs
  // (scrollTop compensation drifts when async data fills cells above
  // the viewport, and the freeze on initial load was caused by the
  // wide ±6 range fetching + rendering thousands of recurring
  // phantoms upfront).
  //
  // Three guards still protect the down-loader from cascading:
  //   - userInteracted gate: inert until the user has actually
  //     touched / wheel'd / scrolled the grid. The initial layout's
  //     programmatic scroll-to-today never triggers loads.
  //   - timestamp cooldown (LOAD_COOLDOWN_MS): at most one load per
  //     window of time, no matter how many scroll events queue.
  //     Stops the "phone-down self-scrolling" cascade.
  //   - one block per fire: keeps each load's JS work bounded.
  const MOBILE_INITIAL_PRIOR = 1;
  const MOBILE_INITIAL_NEXT = 1;
  const EDGE_THRESHOLD_PX = 1500;
  const LOAD_COOLDOWN_MS = 250;

  function activateMobileMonthInfinite(root) {
    if (!root) return;
    const grid = root.querySelector(".cal-month-grid");
    const stack = grid && grid.querySelector("[data-month-stack]");
    if (!grid || !stack) return;
    ensureMobileMqlListener(root);

    if (!isMobileMonthView()) {
      // Desktop / wide-tablet: keep the existing single-block layout.
      teardownMobileInfinite();
      return;
    }

    // Reduce to exactly one block (the server-rendered center or the
    // post-nav target). Subsequent activates (matchMedia transitions,
    // popstate, etc.) trim the previously-built stack down to that
    // single anchor before rebuilding around it.
    let blocks = $$("[data-month-block]", stack);
    if (blocks.length === 0) return;
    if (blocks.length > 1) {
      const centerISO = root.dataset.currentDate?.slice(0, 7);
      const keep = blocks.find((b) => b.dataset.monthIso === centerISO) || blocks[Math.floor(blocks.length / 2)];
      blocks.forEach((b) => { if (b !== keep) b.remove(); });
      blocks = [keep];
    }

    const center = blocks[0];
    const centerISO = center.dataset.monthIso;
    if (!centerISO) return;

    // Build the initial sibling window in a detached fragment first,
    // then insert in two batches. Tiny initial range keeps the first
    // paint fast; the down-loader extends forward as the user
    // scrolls. There is no up-loader, so MOBILE_INITIAL_PRIOR is the
    // hard cap on how far back the user can scroll.
    const priorFrag = document.createDocumentFragment();
    for (let i = MOBILE_INITIAL_PRIOR; i >= 1; i--) {
      const b = buildMonthBlockNode(addMonthsISO(centerISO, -i));
      if (b) priorFrag.appendChild(b); // descending so insertion is chronological
    }
    const nextFrag = document.createDocumentFragment();
    for (let i = 1; i <= MOBILE_INITIAL_NEXT; i++) {
      const b = buildMonthBlockNode(addMonthsISO(centerISO, +i));
      if (b) nextFrag.appendChild(b);
    }

    // Bulk insert. Prior fragment goes above the center; record the
    // height delta and compensate scrollTop in one shot. Direct
    // scrollTop assignment (not scrollTo) sidesteps any pending
    // browser smooth-scroll behavior.
    const beforeH = grid.scrollHeight;
    const beforeTop = grid.scrollTop;
    stack.insertBefore(priorFrag, center);
    const afterH = grid.scrollHeight;
    grid.scrollTop = beforeTop + (afterH - beforeH);

    const downLoader = stack.querySelector('[data-month-loader="down"]');
    if (downLoader) stack.insertBefore(nextFrag, downLoader);
    else stack.appendChild(nextFrag);

    // Single post-mutation pass: extend window markers, fire seed
    // hydration + banner layout + overflow counts. Items hydrate from
    // the store; AgendaSync.ensureRangeLoaded backfills any missing
    // history asynchronously and the existing store subscriber
    // re-renders cells when data arrives.
    expandGridRangeMarkers(grid);
    repaintAfterMutation(grid);

    // Anchor on today after layout settles. Two rAFs: first lets the
    // notify-driven cell renders paint; second is when measurements
    // are stable. We do NOT keep adjusting scrollTop after this — any
    // further scroll motion is the user's, not ours.
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        const todayISO = toISO(new Date());
        const todayCell = grid.querySelector(`.cal-month-cell[data-date="${cssEscape(todayISO)}"]`);
        const gridRect = grid.getBoundingClientRect();
        const weekdaysH = grid.querySelector(".cal-month-weekdays")?.getBoundingClientRect().height || 32;
        let target;
        if (todayCell) {
          const cellRect = todayCell.getBoundingClientRect();
          target = grid.scrollTop + (cellRect.top - gridRect.top) - weekdaysH - 8;
        } else {
          const centerRect = center.getBoundingClientRect();
          target = grid.scrollTop + (centerRect.top - gridRect.top);
        }
        grid.scrollTop = Math.max(0, target);
        bindMobileObservers(root, grid, stack);
      });
    });
  }

  function isMobileMonthView() {
    return window.matchMedia && window.matchMedia("(max-width: 720px)").matches;
  }

  function ensureMobileMqlListener(root) {
    if (mobileInfinite.mql) return;
    if (!window.matchMedia) return;
    const mql = window.matchMedia("(max-width: 720px)");
    mobileInfinite.mql = mql;
    const handler = () => {
      // Re-activate on every transition. When crossing into desktop the
      // activate function tears down observers + leaves the existing
      // blocks (still valid markup). When crossing into mobile it seeds
      // siblings around the current center.
      activateMobileMonthInfinite(root);
    };
    if (mql.addEventListener) mql.addEventListener("change", handler);
    else if (mql.addListener) mql.addListener(handler);
  }

  function teardownMobileInfinite() {
    if (mobileInfinite.scrollHandler && mobileInfinite.scrollGrid) {
      mobileInfinite.scrollGrid.removeEventListener("scroll", mobileInfinite.scrollHandler);
      mobileInfinite.scrollHandler = null;
      mobileInfinite.scrollGrid = null;
    }
    mobileInfinite.observed = false;
  }

  function appendMonthBlock(grid, monthISO) {
    const stack = grid.querySelector("[data-month-stack]");
    if (!stack) return null;
    if (stack.querySelector(`[data-month-block][data-month-iso="${cssEscape(monthISO)}"]`)) return null;
    const block = buildMonthBlockNode(monthISO);
    if (!block) return null;
    const downLoader = stack.querySelector('[data-month-loader="down"]');
    if (downLoader) stack.insertBefore(block, downLoader);
    else stack.appendChild(block);
    expandGridRangeMarkers(grid);
    repaintAfterMutation(grid);
    return block;
  }

  // After bulk-inserting blocks at activate, extend the grid's
  // data-month-start and data-month-end to cover the union of every
  // block. Store queries (itemsForRange, ensureRangeLoaded,
  // hydrateMonthAllDaySeeds) all read these markers, so they have to
  // track the full visible window — not the original single-month
  // range.
  function expandGridRangeMarkers(grid) {
    const stack = grid.querySelector("[data-month-stack]");
    const blocks = $$("[data-month-block]", stack);
    if (blocks.length === 0) return;
    let lo = blocks[0].dataset.blockStart;
    let hi = blocks[0].dataset.blockEnd;
    blocks.forEach((b) => {
      if (b.dataset.blockStart < lo) lo = b.dataset.blockStart;
      if (b.dataset.blockEnd > hi) hi = b.dataset.blockEnd;
    });
    grid.dataset.monthStart = lo;
    grid.dataset.monthEnd = hi;
  }

  // Single shared post-mutation pass: backfill the store, re-hydrate
  // the all-day seed container for the union range, then re-run the
  // banner layout + overflow count. Triggered after every block append
  // or prepend; cheap because layoutMonthBanners early-exits on rows
  // with no candidate banners.
  function repaintAfterMutation(grid) {
    const root = grid.closest(".agenda-cal-page");
    if (!root) return;
    const from = grid.dataset.monthStart;
    const to = grid.dataset.monthEnd;
    if (from && to) window.AgendaSync?.ensureRangeLoaded(from, to);
    rehydrateMonthSeedsFromStore(root);
    layoutMonthBanners(root);
    recountMonthOverflow(root);
    // Wake month_view.js's subscriber so the new cells fill with items.
    window.AgendaStore?.notify?.("page");
  }

  // Bind the scroll handler: throttled title tracker + cooldown-gated
  // edge loader. The edge loader is the only thing that can mutate
  // the stack after activate, and it's protected by THREE guards
  // (user-interaction gate, hard timestamp cooldown, in-flight lock)
  // so a backlog of scroll events can't cascade into runaway loads.
  function bindMobileObservers(root, grid, stack) {
    teardownMobileInfinite();

    // ---- helpers defined first so onScroll can call them without
    // any temporal-dead-zone hazard, and so any throw in the loader
    // never prevents the title tracker from running.
    const titleEl = $(".cal-toolbar-title", root);
    const formatMonthShort = (iso) => {
      const dt = parseISODate(`${iso}-01`);
      // Short month form ("Sep 2026") keeps the title narrow enough
      // that long months ("September 2026") can't push the right-side
      // toolbar controls into overlap.
      return dt.toLocaleDateString(undefined, { month: "short", year: "numeric" });
    };
    const updateTitleFromBlock = (block) => {
      if (!titleEl || !block) return;
      const iso = block.dataset.monthIso;
      if (!iso) return;
      const txt = formatMonthShort(iso);
      if (titleEl.textContent !== txt) titleEl.textContent = txt;
    };
    const pickDominantBlock = () => {
      const gridRect = grid.getBoundingClientRect();
      const weekdaysH = grid.querySelector(".cal-month-weekdays")?.getBoundingClientRect().height || 32;
      // Probe a few px below the weekday header — that's the visual
      // "what month am I reading" point.
      const probeY = gridRect.top + weekdaysH + 4;
      const allBlocks = $$("[data-month-block]", stack);
      // The block whose vertical range [top, bottom] contains the
      // probe line is the dominant one. Exactly one block will match
      // when the stack is contiguous; if no block matches (e.g. the
      // probe is in a divider gap), fall back to the first block whose
      // top is below the probe.
      for (const b of allBlocks) {
        const r = b.getBoundingClientRect();
        if (r.top <= probeY && r.bottom > probeY) return b;
      }
      for (const b of allBlocks) {
        const r = b.getBoundingClientRect();
        if (r.top > probeY) return b;
      }
      return allBlocks[allBlocks.length - 1] || null;
    };

    // User-interaction gate. Initial layout's programmatic scroll-to-
    // today fires scroll events too; without this the loader would
    // see "near the bottom" on first frame and immediately start
    // appending months the user never asked for.
    mobileInfinite.userInteracted = false;
    const markInteracted = () => { mobileInfinite.userInteracted = true; };
    ["wheel", "touchstart", "pointerdown", "keydown"].forEach((evt) => {
      grid.addEventListener(evt, markInteracted, { passive: true, once: true });
    });

    const maybeLoadEdge = () => {
      if (!mobileInfinite.userInteracted) return;
      if (mobileInfinite.loading) return;
      const now = performance.now();
      if (now - mobileInfinite.lastLoadAt < LOAD_COOLDOWN_MS) return;

      // DOWN-only loader. Back-scroll is fixed at activate
      // (MOBILE_INITIAL_PRIOR months); we never prepend during
      // scroll. This eliminates the jump-to-month bug that came from
      // scrollTop compensation drifting when async data filled cells
      // above the viewport.
      const distToBottom = grid.scrollHeight - (grid.scrollTop + grid.clientHeight);
      if (distToBottom >= EDGE_THRESHOLD_PX) return;

      const blocks = $$("[data-month-block]", stack);
      if (blocks.length === 0) return;
      const lastISO = blocks[blocks.length - 1].dataset.monthIso;

      // ONE block per fire — bounds the JS work to ~30ms so the
      // thread stays responsive. The cooldown caps load frequency
      // at 1/250ms ≈ 4 months/sec, comfortably above any natural
      // inertial-scroll velocity (~600px/month × 4 = 2400 px/sec).
      mobileInfinite.loading = true;
      mobileInfinite.lastLoadAt = now;
      try { appendMonthBlock(grid, addMonthsISO(lastISO, +1)); }
      finally { mobileInfinite.loading = false; }
    };

    let scrollScheduled = false;
    const onScroll = () => {
      // Title tracker FIRST + try/catch around the loader. If
      // maybeLoadEdge ever throws (a subscriber error inside
      // repaintAfterMutation, etc.) we must not lose the title
      // update — the user notices a stale title immediately, but a
      // missing edge-load is a degraded-but-recoverable state.
      if (!scrollScheduled) {
        scrollScheduled = true;
        requestAnimationFrame(() => {
          scrollScheduled = false;
          try { updateTitleFromBlock(pickDominantBlock()); }
          catch (e) { console.error("[mobileInfinite] title update failed", e); }
        });
      }
      try { maybeLoadEdge(); }
      catch (e) { console.error("[mobileInfinite] edge load failed", e); }
    };

    grid.addEventListener("scroll", onScroll, { passive: true });
    mobileInfinite.scrollHandler = onScroll;
    mobileInfinite.scrollGrid = grid;

    // Initial paint — covers the case where the activate scroll-to-
    // today landed in a non-server-month, so the toolbar title shouldn't
    // stay on whatever the server rendered.
    updateTitleFromBlock(pickDominantBlock());

    mobileInfinite.observed = true;
  }

  // Smooth-scroll the cell whose data-date matches `dateISO` into view.
  // Used by the Today button on mobile (where prev/next are hidden and
  // scrolling IS the navigation). Falls back to a renderMonthFor if the
  // requested date isn't currently in any rendered block.
  function scrollMonthToDate(root, dateISO) {
    const grid = root.querySelector(".cal-month-grid");
    if (!grid) return false;
    const cell = grid.querySelector(`.cal-month-cell[data-date="${cssEscape(dateISO)}"]`);
    if (!cell) return false;
    const gridRect = grid.getBoundingClientRect();
    const cellRect = cell.getBoundingClientRect();
    const weekdaysH = grid.querySelector(".cal-month-weekdays")?.getBoundingClientRect().height || 32;
    const target = grid.scrollTop + (cellRect.top - gridRect.top) - weekdaysH - 8;
    grid.scrollTo({ top: target, behavior: "smooth" });
    return true;
  }

  function cssEscape(str) {
    return (window.CSS && window.CSS.escape) ? window.CSS.escape(str) : String(str).replace(/"/g, '\\"');
  }

  // --- Date helpers used by client-side nav ---
  // Don't go through native Date for arithmetic — DST shifts can move
  // wall midnight by an hour and corrupt "+7 days". String math
  // against ISO components is timezone-free.
  function parseISODate(iso) {
    const [y, m, d] = String(iso).split("-").map(Number);
    return new Date(y, m - 1, d);
  }
  function addDaysISO(iso, n) {
    const [y, m, d] = String(iso).split("-").map(Number);
    const dt = new Date(Date.UTC(y, m - 1, d + n, 12, 0, 0));
    return `${dt.getUTCFullYear()}-${pad(dt.getUTCMonth() + 1)}-${pad(dt.getUTCDate())}`;
  }
  function mondayOf(iso) {
    const [y, m, d] = String(iso).split("-").map(Number);
    const dt = new Date(Date.UTC(y, m - 1, d, 12, 0, 0));
    const wday = dt.getUTCDay(); // 0=Sun
    const delta = wday === 0 ? -6 : 1 - wday;
    return addDaysISO(iso, delta);
  }

  // Sunday of the week containing `iso`, with Monday as the week start
  // (same convention as AgendasController#cal_week_start_day :monday).
  function sundayOf(iso) {
    const [y, m, d] = String(iso).split("-").map(Number);
    const dt = new Date(Date.UTC(y, m - 1, d, 12, 0, 0));
    const wday = dt.getUTCDay(); // 0=Sun, 1=Mon, ... 6=Sat
    const delta = wday === 0 ? 0 : 7 - wday;
    return addDaysISO(iso, delta);
  }

  // Local-date ISO for a JS Date (uses local year/month/day, not UTC).
  function toISO(dt) {
    return `${dt.getFullYear()}-${pad(dt.getMonth() + 1)}-${pad(dt.getDate())}`;
  }

  // "YYYY-MM" + delta months → "YYYY-MM". Wraps year correctly.
  function addMonthsISO(monthISO, delta) {
    const [yStr, mStr] = String(monthISO).split("-");
    const year = parseInt(yStr, 10);
    const month0 = parseInt(mStr, 10) - 1 + delta;
    const dt = new Date(year, month0, 1);
    return `${dt.getFullYear()}-${pad(dt.getMonth() + 1)}`;
  }

  function todayMonthISO() {
    const dt = new Date();
    return `${dt.getFullYear()}-${pad(dt.getMonth() + 1)}`;
  }

  function installNavInterception(root) {
    // Delegated on root — works across innerHTML swaps.
    root.addEventListener("click", (e) => {
      if (e.defaultPrevented) return;
      if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;
      if (e.button !== undefined && e.button !== 0) return;
      const link = e.target.closest(
        ".cal-toolbar-nav a, .cal-toolbar-toggle a, .cal-today-btn"
      );
      if (!link) return;
      // External / new-tab / hash links: let the browser handle.
      if (link.target === "_blank" || !link.href) return;
      const url = new URL(link.href, window.location.href);
      if (url.origin !== window.location.origin) return;
      // Mobile month view: Today button scrolls the today cell into
      // view rather than navigating. The cell is virtually always in
      // the stack (server-rendered current month + seeded siblings); if
      // somehow it isn't, fall through to the normal nav.
      if (link.classList.contains("cal-today-btn")
          && root.classList.contains("agenda-cal-month-page")
          && isMobileMonthView()) {
        const todayISO = toISO(new Date());
        if (scrollMonthToDate(root, todayISO)) {
          e.preventDefault();
          return;
        }
      }
      if (url.pathname === window.location.pathname && url.search === window.location.search) {
        // Same URL — still useful (e.g. "Today" when already on this
        // week). Treat as a no-op rather than a reload.
        e.preventDefault();
        return;
      }
      e.preventDefault();
      navigateClientSide(url);
    });

    // popstate: browser back/forward needs to re-render against the
    // restored URL. Without this, hitting Back after a client-side jump
    // updates the URL but leaves the grid pinned on the previous
    // week/month.
    window.addEventListener("popstate", () => {
      const onWeek = root.classList.contains("agenda-cal-week-page");
      const onMonth = root.classList.contains("agenda-cal-month-page");
      const params = new URLSearchParams(window.location.search);
      if (onWeek) {
        const targetISO = params.get("date") || logicalDateISO(new Date(), 3);
        renderWeekFor(root, targetISO);
      } else if (onMonth) {
        const targetMonthISO = params.get("month") || todayMonthISO();
        renderMonthFor(root, targetMonthISO);
      }
    });
  }

  // ============================================================
  // COMMON: drag mousemove/mouseup, refresh, day-roll
  // ============================================================
  let commonHandlersInstalled = false;
  function bindCommonHandlers() {
    if (commonHandlersInstalled) return;
    commonHandlersInstalled = true;

    document.addEventListener("mousemove", (e) => {
      // ---- blocked-drag (read-only event the user is trying to drag) ----
      // No DOM mutation — just flip the body cursor to `not-allowed`
      // once they've moved enough that it's clearly a drag attempt.
      if (eventDragBlocked.btn && !eventDragBlocked.moved) {
        const dx = e.clientX - eventDragBlocked.startX;
        const dy = e.clientY - eventDragBlocked.startY;
        if (Math.hypot(dx, dy) >= EVENT_DRAG_THRESHOLD_PX) {
          eventDragBlocked.moved = true;
          document.body.classList.add("cal-event-drag-blocked");
        }
      }
      // ---- event-drag (move existing event) ----
      if (eventDrag.btn) {
        const dx = e.clientX - eventDrag.startX;
        const dy = e.clientY - eventDrag.startY;
        if (!eventDrag.moved && Math.hypot(dx, dy) < EVENT_DRAG_THRESHOLD_PX) return;
        if (!eventDrag.moved) {
          // Promote to real drag — build the ghost + placeholder once.
          eventDrag.moved = true;
          eventDrag.btn.classList.add("is-dragging-source");
          eventDrag.btn.style.pointerEvents = "none";
          // Body-level class so the `grabbing` cursor sticks no matter
          // what region of the viewport the cursor passes over during
          // the drag (gutter, toolbar, gaps between columns, etc.).
          document.body.classList.add("cal-event-dragging");

          // Ghost = clone of the original, position:fixed so it tracks
          // the cursor regardless of grid scroll.
          const btnRect = eventDrag.btn.getBoundingClientRect();
          eventDrag.grabOffsetY = eventDrag.startY - btnRect.top;
          // Travel band height — used to size the placeholder to the
          // EVENT portion only and to offset drop math by the band so
          // the dropped `start_at` lands at the event's start, not the
          // band's top. Without this, dragging an event with a 218m
          // travel band visually showed the placeholder at e.g. "7am"
          // (the band's top) but on drop set the event start to 7am,
          // backing the band up into the early morning. Now the
          // placeholder represents exactly where the event will land.
          // Pre-event band only — `.is-post` lives BELOW the event and
          // doesn't affect grab-to-event-top math.
          const bandEl = eventDrag.btn.querySelector(".cal-week-event-travel:not(.is-post)");
          const bandPx = bandEl ? bandEl.getBoundingClientRect().height : 0;
          eventDrag.bandPx = bandPx;
          const ghost = eventDrag.btn.cloneNode(true);
          ghost.classList.remove("is-dragging-source");
          ghost.classList.add("cal-week-drag-ghost");
          ghost.style.position = "fixed";
          ghost.style.pointerEvents = "none";
          ghost.style.zIndex = "9999";
          ghost.style.top = "";
          ghost.style.left = "";
          ghost.style.right = "";
          ghost.style.width = `${btnRect.width}px`;
          ghost.style.height = `${btnRect.height}px`;
          document.body.appendChild(ghost);
          eventDrag.ghost = ghost;

          // Placeholder = a dashed outline that shows the user where the
          // event will land. Inserted into the drop column on each
          // mousemove. Height excludes the travel band so the
          // placeholder represents the event's true slot — the band
          // gets recomputed for the new start_at after drop anyway.
          const eventPx = Math.max(0, btnRect.height - bandPx);
          const ph = document.createElement("div");
          ph.className = "cal-week-drop-placeholder";
          ph.style.height = `${eventPx}px`;
          ph.style.setProperty("--agenda-color", eventDrag.btn.dataset.agendaColor || "#888");
          eventDrag.placeholder = ph;
        }

        // Move the ghost with the cursor.
        if (eventDrag.ghost) {
          const ghostRect = eventDrag.ghost.getBoundingClientRect();
          eventDrag.ghost.style.left = `${e.clientX - 20}px`;
          eventDrag.ghost.style.top = `${e.clientY - eventDrag.grabOffsetY}px`;
        }

        // Find drop column under cursor; the source btn has
        // pointer-events:none and the ghost is on body, so neither
        // shadow the column under the cursor.
        const targetCol = document.elementFromPoint(e.clientX, e.clientY)
          ?.closest(".cal-week-column[data-date]");
        const ph = eventDrag.placeholder;
        if (!ph) return;
        if (targetCol) {
          const { snapPx, pxPerMin, grid } = eventDrag.ctx;
          const colRect = targetCol.getBoundingClientRect();
          // `grabOffsetY` is measured from the TILE top (band + content).
          // Add `bandPx` so we land the placeholder at the EVENT top —
          // the placeholder represents the event's slot, not the tile's.
          const bandPx = eventDrag.bandPx || 0;
          const targetY = snapPxDown(e.clientY - colRect.top - eventDrag.grabOffsetY + bandPx, snapPx);
          if (ph.parentElement !== targetCol) targetCol.appendChild(ph);
          ph.style.top = `${targetY}px`;
          const dayStart = Number(grid?.dataset?.dayStartHour) || 0;
          const origStart = Number(eventDrag.btn.dataset.startAt);
          const origEnd = Number(eventDrag.btn.dataset.endAt) || origStart;
          const durMin = Math.max(15, Math.round((origEnd - origStart) / 60));
          const startClock = (dayStart * 60 + targetY / pxPerMin) % (24 * 60);
          const endClock = (startClock + durMin) % (24 * 60);
          ph.textContent = `${formatLabelTime(startClock)} – ${formatLabelTime(endClock)}`;
          eventDrag.dropCol = targetCol;
          eventDrag.dropTop = targetY;
        } else if (ph.parentElement) {
          ph.remove();
          eventDrag.dropCol = null;
        }
      }
      // ---- month drag ----
      if (monthDrag.startCell) {
        const el = document.elementFromPoint(e.clientX, e.clientY);
        const cell = el && el.closest(".cal-month-cell[data-date]");
        if (cell && cell !== monthDrag.lastCell) {
          monthDrag.lastCell = cell;
          monthDrag.moved = true;
          const root = cell.closest(".agenda-cal-month-page");
          if (root) paintMonthDragRange(root, monthDrag.startCell, cell);
        }
      }
      // ---- all-day drag (date-range select) ----
      if (allDayDrag.startCell) {
        // Find which all-day cell the cursor is over right now. If none
        // (cursor left the strip), keep the current selection in place.
        const hit = document.elementFromPoint(e.clientX, e.clientY)
          ?.closest(".cal-week-allday-cell");
        if (hit && hit !== allDayDrag.currentCell) {
          allDayDrag.currentCell = hit;
          allDayDrag.moved = true;
          paintAllDayDragSelection(allDayDrag.root, allDayDrag.startCell, hit);
        } else if (hit && !allDayDrag.moved) {
          // Cursor still on the start cell but the user may be just
          // hovering — leave the highlight as-is.
        }
        // Don't `return` — we want to keep both drags exclusive of each
        // other anyway, and weekDrag.col will be null when this branch
        // is the active drag.
      }
      // ---- week drag ----
      if (weekDrag.col) {
        const { snapPx, pxPerMin } = weekDrag.ctx;
        const rect = weekDrag.col.getBoundingClientRect();
        const y = e.clientY - rect.top;
        const delta = y - weekDrag.startPx;
        if (!weekDrag.moved && Math.abs(delta) < 4) return;
        weekDrag.moved = true;
        if (weekDrag.sel) weekDrag.sel.classList.remove("hidden");
        const isUp = delta < 0;
        const cursor = isUp ? snapPxDown(y, snapPx) : snapPxUp(y, snapPx);
        let top = Math.min(weekDrag.startPx, cursor);
        let bottom = Math.max(weekDrag.startPx, cursor);
        if (bottom - top < snapPx) bottom = top + snapPx;
        weekDrag.top = top;
        weekDrag.bottom = bottom;
        if (weekDrag.sel) {
          weekDrag.sel.style.top = `${top}px`;
          weekDrag.sel.style.height = `${bottom - top}px`;
          const grid = weekDrag.col.closest(".cal-week-grid");
          const dayStart = Number(grid?.dataset?.dayStartHour) || 0;
          const startClock = (dayStart * 60 + top / pxPerMin) % (24 * 60);
          const endClock = (dayStart * 60 + bottom / pxPerMin) % (24 * 60);
          weekDrag.sel.textContent = `${formatLabelTime(startClock)} – ${formatLabelTime(endClock)}`;
        }
      }
    });

    document.addEventListener("mouseup", (e) => {
      // ---- blocked-drag finish ----
      // Always clear (whether the threshold was crossed or not). Don't
      // return here — if the user never crossed the threshold, the
      // mouseup-on-button → click → details-modal path still needs to
      // run for the natural click.
      if (eventDragBlocked.btn) clearBlockedDrag();
      // ---- event-drag finish ----
      if (eventDrag.btn) {
        const btn = eventDrag.btn;
        const moved = eventDrag.moved;
        const ctx = eventDrag.ctx;
        const dropCol = eventDrag.dropCol;
        const dropTop = eventDrag.dropTop;
        if (moved) {
          // Use the placeholder's final position as the destination
          // (already snapped to the slot, validated against a column).
          if (dropCol && ctx) {
            const { pxPerMin, grid } = ctx;
            const dayStart = Number(grid.dataset.dayStartHour) || 0;
            // `dropTop` is the EVENT top (placeholder was sized + offset
            // to event-only, excluding the travel band). That's exactly
            // what newStartAt math needs. For the inline DOM move we
            // need the TILE top (band + event), so subtract bandPx
            // when positioning the button so the visible event content
            // sits at the placeholder's location.
            const bandPx = eventDrag.bandPx || 0;
            const newStartMin = dropTop / pxPerMin;
            const origStart = Number(btn.dataset.startAt);
            const origEnd = Number(btn.dataset.endAt) || origStart;
            const durSec = Math.max(900, origEnd - origStart);
            const newStartAt = computeEpochForLogicalSlot(dropCol.dataset.date, dayStart, newStartMin);
            const newEndAt = newStartAt + durSec;
            // Snapshot before applyInlineMove so a cancelled
            // recurring-scope choice can put the tile back exactly.
            const snap = captureTileState(btn);
            applyInlineMove(btn, dropCol, dropTop - bandPx, pxPerMin);
            applyInlineTimeLabel(btn, newStartAt, newEndAt);
            sendEventMove(btn, newStartAt, newEndAt, snap);
          }
          // Tear down ghost + placeholder, restore the source button.
          cancelEventDrag();
          armClickSuppressor();
          return;
        }
        // No movement = it was a click. Reset state without ghost teardown
        // (none was created) and let the natural click fall through.
        eventDrag.btn = null;
        eventDrag.moved = false;
        eventDrag.ctx = null;
        eventDrag.dropCol = null;
        btn.style.pointerEvents = "";
        const upEl = document.elementFromPoint(e.clientX, e.clientY);
        const onButton = upEl && upEl.closest(".cal-week-event") === btn;
        if (!onButton) {
          setTimeout(() => btn.click(), 0);
        }
      }
      // ---- month drag finish ----
      if (monthDrag.startCell) {
        const wasMoved = monthDrag.moved;
        const startCell = monthDrag.startCell;
        const lastCell = monthDrag.lastCell;
        const root = startCell.closest(".agenda-cal-month-page");
        monthDrag.startCell = null;
        monthDrag.lastCell = null;
        monthDrag.moved = false;
        if (root) clearMonthDragHighlight(root);
        if (wasMoved) {
          const a = startCell.dataset.date;
          const b = lastCell.dataset.date;
          const lo = compareISO(a, b) <= 0 ? a : b;
          const hi = compareISO(a, b) <= 0 ? b : a;
          if (lo === hi) openAddModalForDate(lo);
          else openAddModalForRange(lo, hi, true);
          // The mouseup that just finished the drag emits a synthesized
          // click in some browsers; modals.js would interpret it as a
          // click outside the just-opened modal and close it.
          armClickSuppressor();
        }
      }
      // ---- all-day drag finish ----
      if (allDayDrag.startCell) {
        const startCell = allDayDrag.startCell;
        const endCell = allDayDrag.currentCell || allDayDrag.startCell;
        const moved = allDayDrag.moved;
        const root = allDayDrag.root;
        allDayDrag.startCell = null;
        allDayDrag.currentCell = null;
        allDayDrag.moved = false;
        allDayDrag.root = null;
        clearAllDayDragSelection(root);
        const startDate = startCell.dataset.date;
        const endDate = endCell.dataset.date;
        // Single-cell click ALSO opens the add modal — mirrors the
        // body-grid `dblclick` behavior, but on a single click since the
        // all-day strip has no fine-grained selection to disambiguate.
        const lo = startDate <= endDate ? startDate : endDate;
        const hi = startDate <= endDate ? endDate : startDate;
        openAddModalForRange(lo, hi, true);
        if (moved) armClickSuppressor();
      }
      // ---- week drag finish ----
      if (weekDrag.col) {
        const { pxPerMin } = weekDrag.ctx;
        const moved = weekDrag.moved;
        const col = weekDrag.col;
        const top = weekDrag.top;
        const bottom = weekDrag.bottom;
        weekDrag.col = null;
        weekDrag.sel?.classList.add("hidden");
        if (weekDrag.sel) { weekDrag.sel.textContent = ""; weekDrag.sel.style.height = ""; }
        if (moved) {
          const grid = col.closest(".cal-week-grid");
          const dayStart = Number(grid?.dataset?.dayStartHour) || 0;
          const startClock = (dayStart * 60 + top / pxPerMin) % (24 * 60);
          const endClock = (dayStart * 60 + bottom / pxPerMin) % (24 * 60);
          openAddModalForTime(col.dataset.date, startClock, endClock);
          armClickSuppressor();
        }
      }
    });
  }

  // ============================================================
  // LIVE REFRESH
  // ============================================================
  // We refresh in place by fetching the same page URL, pulling out the
  // data containers, and swapping them. No reload.
  //
  // Refresh triggers (in order of priority):
  //   1) Monitor "agenda" broadcast — picked up by agenda.js's received
  //      handler which delegates to `window.__refreshAgendaCal`.
  //   2) Monitor reconnect — agenda.js's connected callback re-fires
  //      refreshView, catching anything missed while offline.
  //   3) Tab visibility change → visible — agenda.js already does this.
  //   4) Window focus — added below for desktop PWAs where the OS may
  //      pause the WebSocket without changing visibility.
  //   5) Network online event — added below for the case where the
  //      device went offline (Monitor disconnected) and came back.
  //
  // If a Monitor broadcast arrives while a modal is open or an input
  // is focused, the refresh is deferred (`refreshDirty = true`) and the
  // MutationObserver / focusout listener fires it as soon as the user
  // dismisses the modal or blurs the input.
  let refreshDirty = false;
  let refreshInFlight = null;
  let refreshInFlightAt = 0;
  // Cap a stuck fetch (PWA suspended mid-request, network stall) so a
  // hung promise can't permanently block subsequent refreshes.
  const REFRESH_FETCH_TIMEOUT_MS = 12_000;
  const REFRESH_INFLIGHT_STALE_MS = 20_000;

  function installRefreshTriggers(root) {
    // When a modal closes / focus leaves an input / a drag ends, replay
    // any deferred refresh. MutationObserver watches `.modal.shown` and
    // `.is-dragging-source` class flicker so both interactions trigger
    // a flush. focusout covers input blur.
    new MutationObserver(() => {
      if (refreshDirty && !isInteracting()) runRefresh();
    }).observe(document.body, { subtree: true, attributes: true, attributeFilter: ["class"] });

    document.addEventListener("focusout", () => {
      setTimeout(() => {
        if (refreshDirty && !isInteracting()) runRefresh();
      }, 50);
    });

    // Belt-and-suspenders: PWAs in standalone mode sometimes lose the
    // WebSocket without firing the ActionCable disconnect event (OS
    // sleep, App Nap on macOS, etc.). When the window regains focus or
    // the network reports online, force a refresh so we catch up on
    // anything we missed while suspended.
    window.addEventListener("focus", () => {
      const grid = root.querySelector(".cal-week-grid, .cal-month-grid");
      const dayStart = Number(grid?.dataset?.dayStartHour) || 3;
      updateTodayBtnState(root, dayStart);
      window.__refreshAgendaCal?.();
    });
    window.addEventListener("online", () => {
      window.__refreshAgendaCal?.();
    });
  }

  function inputBusy() {
    const a = document.activeElement;
    return !!(a && ["INPUT", "TEXTAREA", "SELECT"].includes(a.tagName));
  }

  // A refresh in-flight tears down + re-renders the event blocks via
  // `buildWeekBlocks`. If the user is in the middle of dragging one of
  // those blocks (or click-dragging to create / drag-selecting in
  // month), the dragged node would be ripped out from under them. Defer
  // the refresh until the interaction completes — the MutationObserver
  // catches the `.is-dragging-source` class flip and fires it then.
  function isInteracting() {
    if (document.querySelector(".modal.shown")) return true;
    if (inputBusy()) return true;
    if (eventDrag.btn) return true;     // dragging an existing event
    if (weekDrag.col) return true;      // drag-create on the time grid
    if (monthDrag.startCell) return true; // drag-select on month cells
    return false;
  }

  window.__refreshAgendaCal = function () {
    if (isInteracting()) {
      refreshDirty = true;
      return;
    }
    runRefresh();
  };

  // Local-only rebuild — no fetch. Called from agenda.js whenever a
  // filter pref changes, so the timed-grid lanes reflow LIVE (while the
  // details modal is still open) instead of waiting for the post-modal
  // refresh tick. Safe to call any time; no-ops off the cal pages. The
  // re-entry guard breaks the loop with applyAgendaVisibility — which
  // itself chains back to here so non-cal pages still pick up the
  // visibility classes.
  let calRebuildInFlight = false;
  window.__rebuildAgendaCalLocal = function () {
    if (calRebuildInFlight) return;
    const root = $(".agenda-cal-page");
    if (!root) return;
    calRebuildInFlight = true;
    try {
      if (root.classList.contains("agenda-cal-week-page")) {
        buildWeekBlocks(root);
      } else if (root.classList.contains("agenda-cal-month-page")) {
        rehydrateMonthSeedsFromStore(root);
        layoutMonthBanners(root);
        recountMonthOverflow(root);
      }
    } finally {
      calRebuildInFlight = false;
    }
  };

  // Jump to the date of a freshly-created event on the cal views. Both
  // /agenda/grid (week) and /agenda/month route here. The list views
  // (`agenda-day-page` / `agenda-week-page`) install their own hook with
  // the same name in `list_view.js`, so each shell self-registers and
  // the submit path can call `window.__agendaJumpToDate(epochSec)`
  // without caring which surface it's on.
  function installCalJumpHook(root) {
    window.__agendaJumpToDate = (epochSec) => {
      if (!epochSec) return;
      const d = new Date(Number(epochSec) * 1000);
      const isoDate = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
      if (root.classList.contains("agenda-cal-week-page")) {
        const url = `/agenda/grid?date=${isoDate}`;
        history.pushState(null, "", url);
        renderWeekFor(root, isoDate);
      } else if (root.classList.contains("agenda-cal-month-page")) {
        const monthISO = `${d.getFullYear()}-${pad(d.getMonth() + 1)}`;
        const url = `/agenda/month?month=${monthISO}`;
        // Skip when already on the target month — saves a redundant
        // grid rebuild.
        const grid = root.querySelector(".cal-month-grid");
        const currentMonthMatches = grid && (() => {
          const ms = grid.dataset.monthStart;
          if (!ms) return false;
          return ms.startsWith(monthISO);
        })();
        if (currentMonthMatches) return;
        history.pushState(null, "", url);
        renderMonthFor(root, monthISO);
      }
    };
  }

  function runRefresh() {
    // Now backed by AgendaSync's delta path — server returns only the
    // items + schedules changed since the last server_ts, and the
    // store subscriber re-paints via buildWeekBlocks. No HTML refetch,
    // no full template render.
    refreshDirty = false;
    if (window.AgendaSync) {
      window.AgendaSync.scheduleDelta();
      return;
    }
    // Fallback for the (vanishingly small) case where AgendaSync didn't
    // load: legacy HTML-snapshot refresh from the same URL.
    if (refreshInFlight && Date.now() - refreshInFlightAt > REFRESH_INFLIGHT_STALE_MS) {
      refreshInFlight = null;
    }
    if (refreshInFlight) return;
    const root = $(".agenda-cal-page");
    if (!root) return;
    refreshInFlightAt = Date.now();
    const url = window.location.pathname + window.location.search;
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), REFRESH_FETCH_TIMEOUT_MS);
    refreshInFlight = fetch(url, {
      credentials: "same-origin",
      headers: { "Accept": "text/html", "X-Requested-With": "XMLHttpRequest" },
      signal: controller.signal,
    })
      .then((r) => (r.ok ? r.text() : null))
      .then((html) => {
        if (!html) return;
        const doc = new DOMParser().parseFromString(html, "text/html");
        applyHtmlSnapshot(root, doc);
      })
      .catch((err) => {
        if (err && err.name !== "AbortError") {
          console.warn("[agenda-cal] refresh failed", err);
        }
        refreshDirty = true;
      })
      .finally(() => {
        clearTimeout(timer);
        refreshInFlight = null;
      });
  }

  function applyHtmlSnapshot(root, doc) {
    if (root.classList.contains("agenda-cal-month-page")) {
      const oldGrid = root.querySelector(".cal-month-grid");
      const newGrid = doc.querySelector(".cal-month-grid");
      if (oldGrid && newGrid) {
        oldGrid.replaceWith(newGrid);
        // Listeners are delegated on `root`, so they keep working.
        // Reapply visibility BEFORE banner layout / overflow counts so
        // `.hidden-by-filter` rows don't claim layout space or "+N more"
        // budget.
        window.__applyAgendaVisibility?.();
        layoutMonthBanners(root);
        recountMonthOverflow(root);
      }
    } else if (root.classList.contains("agenda-cal-week-page")) {
      // Swap only the seeds (and the day-of headers, which carry today
      // markers that flip after midnight). Keep the time grid scaffold so
      // the user's scroll position is preserved.
      const newSeeds = doc.querySelector(".cal-week-seeds");
      const oldSeeds = root.querySelector(".cal-week-seeds");
      if (newSeeds && oldSeeds) oldSeeds.replaceWith(newSeeds);
      const newHeader = doc.querySelector(".cal-week-header");
      const oldHeader = root.querySelector(".cal-week-header");
      if (newHeader && oldHeader) oldHeader.replaceWith(newHeader);
      const newCols = doc.querySelectorAll(".cal-week-column");
      const oldCols = root.querySelectorAll(".cal-week-column");
      // Re-apply per-column today highlight without recreating columns
      // (which would lose drag state). Just toggle classes.
      const dayStart = Number(root.querySelector(".cal-week-grid")?.dataset?.dayStartHour) || 0;
      const todayISO = logicalDateISO(new Date(), dayStart);
      oldCols.forEach((c) => c.classList.toggle("is-today", c.dataset.date === todayISO));
      const newAlldayCells = doc.querySelectorAll(".cal-week-allday-cell");
      const oldAlldayCells = root.querySelectorAll(".cal-week-allday-cell");
      oldAlldayCells.forEach((c) => c.classList.toggle("is-today", c.dataset.date === todayISO));
      buildWeekBlocks(root);
    }
  }

  // ============================================================
  // DAY ROLLOVER
  // ============================================================
  // Does the currently displayed view contain today?
  //   week  — today falls inside [weekStart, weekEnd]
  //   month — today's YYYY-MM matches the viewed month
  function isViewingToday(root, dayStart) {
    const today = logicalDateISO(new Date(), dayStart);
    if (root.classList.contains("agenda-cal-week-page")) {
      const grid = root.querySelector(".cal-week-grid");
      const ws = grid?.dataset?.weekStart;
      const we = grid?.dataset?.weekEnd;
      if (!ws || !we) return false;
      return compareISO(today, ws) >= 0 && compareISO(today, we) <= 0;
    }
    if (root.classList.contains("agenda-cal-month-page")) {
      const cur = root.dataset.currentDate;
      if (!cur) return false;
      return cur.slice(0, 7) === today.slice(0, 7);
    }
    return false;
  }

  // The "Today" pill in the toolbar gets a tinted state whenever the user
  // is off today's view, so they can spot at a glance that they've
  // navigated away. Toggled on init, after every in-page render, and on
  // each rollover tick + focus event.
  function updateTodayBtnState(root, dayStart) {
    const btn = root.querySelector(".cal-today-btn");
    if (!btn) return;
    btn.classList.toggle("is-off-today", !isViewingToday(root, dayStart));
  }

  // Set the load-time "anchored to today" flag — read by handleDayRollover
  // to decide whether to auto-navigate on midnight / refocus. Stored on
  // the root dataset so it survives the per-call closure boundary.
  function setAnchoredToToday(root, dayStart) {
    root.dataset.anchoredToToday = isViewingToday(root, dayStart) ? "1" : "0";
  }

  function msUntilNextLogicalDay(dayStartHour) {
    const now = new Date();
    const next = new Date(now);
    next.setHours(dayStartHour, 0, 5, 0);
    if (next <= now) {
      next.setDate(next.getDate() + 1);
      next.setHours(dayStartHour, 0, 5, 0);
    }
    return Math.max(next - now, 60_000);
  }

  function scheduleDayRollover(root) {
    const grid = root.querySelector(".cal-week-grid, .cal-month-grid");
    const dayStart = Number(grid?.dataset?.dayStartHour) || 3;
    let lastSeenDate = logicalDateISO(new Date(), dayStart);
    const tick = () => {
      lastSeenDate = logicalDateISO(new Date(), dayStart);
      handleDayRollover(root, dayStart);
      setTimeout(tick, msUntilNextLogicalDay(dayStart));
    };
    setTimeout(tick, msUntilNextLogicalDay(dayStart));

    // setTimeout doesn't fire across device sleep / PWA backgrounding, so
    // re-check on foreground. Always re-evaluate the Today-button state
    // on refocus (the calendar date may have crossed midnight while the
    // PWA was suspended even when the same week is still in view); only
    // run the full rollover handler when the logical date has actually
    // changed since the last tick.
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState !== "visible") return;
      updateTodayBtnState(root, dayStart);
      const now = logicalDateISO(new Date(), dayStart);
      if (now === lastSeenDate) return;
      lastSeenDate = now;
      handleDayRollover(root, dayStart);
    });
  }

  function handleDayRollover(root, dayStart) {
    // Only snap back to today if the user was anchored to today when the
    // page loaded. A deep-link or user-driven navigation away from today
    // is preserved — they stay on the date they chose; the Today pill
    // just lights up so they can see they're not on today.
    const anchored = root.dataset.anchoredToToday === "1";
    if (anchored && !isViewingToday(root, dayStart)) {
      if (root.classList.contains("agenda-cal-week-page")) {
        window.location.assign("/agenda/grid");
        return;
      }
      if (root.classList.contains("agenda-cal-month-page")) {
        window.location.assign("/agenda/month");
        return;
      }
    }
    // Same range OR user navigated away on purpose — refresh in place so
    // today markers + carry-over re-render with the new logical date, and
    // light up the Today pill if needed.
    updateTodayBtnState(root, dayStart);
    window.__refreshAgendaCal();
  }

  // ============================================================
  // ENTRY
  // ============================================================
  document.addEventListener("DOMContentLoaded", () => {
    const monthRoot = $(".agenda-cal-month-page");
    const weekRoot = $(".agenda-cal-week-page");
    if (monthRoot) initMonthView(monthRoot);
    if (weekRoot) initWeekView(weekRoot);
  });
})();
