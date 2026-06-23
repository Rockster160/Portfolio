// Agenda Quick Add modal controller. Wires the natural-language input
// → live preview → mutation queue. The parser is the pure module
// `quick_add_parser.js` (covered by quick_add_parser_spec.rb). This
// file owns DOM + side effects only.

(function () {
  if (typeof window === "undefined") return;

  document.addEventListener("DOMContentLoaded", () => {
    const modal = document.getElementById("agenda-quick-add");
    if (!modal) return;
    const form = modal.querySelector(".agenda-quick-form");
    if (!form) return;

    const input       = form.querySelector(".quick-add-input");
    const previewWrap = form.querySelector("[data-quick-preview]");
    const previewName = form.querySelector("[data-preview-name]");
    const previewWhen = form.querySelector("[data-preview-when]");
    const errorEl     = form.querySelector("[data-quick-error]");
    const submitBtn   = form.querySelector("[data-quick-submit]");
    const advBtn      = form.querySelector("[data-quick-advanced]");
    const examples    = form.querySelectorAll("[data-quick-example]");

    let lastParse = null;

    function parseCurrent() {
      const parser = window.AgendaQuickAddParser;
      if (!parser) return null;
      // Pass writable agendas so "<AgendaName> to <event>" can route to
      // the named agenda. Google-source / read-only ones are excluded
      // since the quick-add path creates a new local item.
      const agendas = (window.AgendaStore?.getAgendas?.() || [])
        .filter((a) => a.editable !== false && a.source !== "google")
        .map((a) => ({ id: a.id, name: a.name }));
      return parser.parseQuickAdd(input.value, { now: new Date(), agendas });
    }

    function paintPreview() {
      const r = parseCurrent();
      lastParse = r;
      if (!r || !r.ok) {
        previewWrap.classList.add("hidden");
        errorEl.classList.add("hidden");
        errorEl.textContent = "";
        submitBtn.disabled = true;
        return;
      }
      previewName.textContent = r.location ? `${r.name} @ ${r.location}` : r.name;
      previewWhen.textContent = formatWhen(r.hints.startDate, r.hints.endDate, r.durationMin, r.allDay);
      previewWrap.classList.remove("hidden");
      errorEl.classList.add("hidden");
      submitBtn.disabled = false;
    }

    function formatWhen(start, end, durationMin, allDay) {
      // For all-day events the user-meaningful end is the INCLUSIVE last
      // day (Google's `end_at` is the exclusive next-day midnight), so
      // walk back 1ms to land on the last covered date for display.
      const inclusiveEnd = allDay ? new Date(end.getTime() - 1) : end;
      const sameDay = (
        start.getFullYear() === inclusiveEnd.getFullYear() &&
        start.getMonth() === inclusiveEnd.getMonth() &&
        start.getDate() === inclusiveEnd.getDate()
      );
      const dayLabel = relativeDayLabel(start);
      if (allDay) {
        return sameDay
          ? `${dayLabel} · All day`
          : `${dayLabel} → ${endDayLabel(inclusiveEnd)} · All day`;
      }
      const time = (d) => d.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
      const dur = formatDuration(durationMin);
      if (sameDay) {
        return `${dayLabel} · ${time(start)} – ${time(end)}  (${dur})`;
      }
      return `${dayLabel} ${time(start)} → ${endDayLabel(end)} ${time(end)}  (${dur})`;
    }

    function relativeDayLabel(d) {
      const today = new Date();
      today.setHours(0, 0, 0, 0);
      const target = new Date(d.getFullYear(), d.getMonth(), d.getDate());
      const deltaDays = Math.round((target - today) / (24 * 3600 * 1000));
      if (deltaDays === 0) return "Today";
      if (deltaDays === 1) return "Tomorrow";
      if (deltaDays >= 2 && deltaDays <= 6) {
        return d.toLocaleDateString(undefined, { weekday: "long" });
      }
      return d.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
    }

    function endDayLabel(d) {
      return d.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
    }

    function formatDuration(min) {
      if (min < 60)        return `${min} min`;
      if (min % 60 === 0)  return `${min / 60} hr`;
      const h = Math.floor(min / 60);
      const m = min - h * 60;
      return `${h} hr ${m} min`;
    }

    function resolveDefaultAgendaId() {
      // 1. The form's data-default-agenda-id (caller hint).
      const fromAttr = form.dataset.defaultAgendaId;
      if (fromAttr) return Number(fromAttr);
      // 2. The active agenda from AgendaStore.
      const agendas = window.AgendaStore?.getAgendas?.() || [];
      const writable = agendas.find((a) => a.editable !== false && a.source !== "google");
      if (writable) return writable.id;
      if (agendas.length) return agendas[0].id;
      return null;
    }

    function agendaMetaFor(agendaId) {
      const a = window.AgendaStore?.getAgenda?.(agendaId);
      if (!a) return { color: "", name: "", source: "" };
      return { color: a.color || "", name: a.name || "", source: a.source || "" };
    }

    function submit() {
      if (!lastParse || !lastParse.ok) return;
      // Parser routing wins over the form's default: "<AgendaName> to
      // <event>" stamps lastParse.agendaId so the event lands on the
      // named agenda even when another one is active.
      const agendaId = lastParse.agendaId || resolveDefaultAgendaId();
      if (!agendaId) {
        errorEl.textContent = "No agenda available — open Advanced to pick one.";
        errorEl.classList.remove("hidden");
        return;
      }
      const meta = agendaMetaFor(agendaId);
      const mid    = window.AgendaMutationQueue.newMutationId();
      const tempId = window.AgendaMutationQueue.newTempId();
      const optimistic = window.AgendaOptimisticItem.buildOptimisticItem({
        id:                  tempId,
        client_mutation_id:  mid,
        name:                lastParse.name,
        kind:                "event",
        color:               meta.color,
        start_at:            lastParse.startAt,
        end_at:              lastParse.endAt,
        all_day:             !!lastParse.allDay,
        location:            lastParse.location || "",
        notes:               "",
        arrive_early_minutes: 0,
        agenda_id:           agendaId,
        agenda_name:         meta.name,
        agenda_color:        meta.color,
        agenda_source:       meta.source,
      });
      window.AgendaStore.upsertItem(optimistic);
      window.AgendaMutationQueue.enqueue({
        client_mutation_id: mid,
        kind:               "create",
        url:                form.dataset.itemUrl,
        method:             "POST",
        body:               {
          agenda_item: {
            agenda_id:          agendaId,
            name:               lastParse.name,
            kind:               "event",
            start_at:           lastParse.startAt,
            end_at:             lastParse.endAt,
            all_day:            !!lastParse.allDay,
            color:              meta.color,
            location:           lastParse.location || "",
            client_mutation_id: mid,
          },
        },
        target_id: tempId,
      });
      window.AgendaMutationQueue.flush();
      // Jump the visible view to whichever date the new event lives on
      // so the user can see it. The hook is registered by whichever
      // shell is mounted (list_view OR agenda_cal) and routes to the
      // right re-render function automatically.
      try { window.__agendaJumpToDate?.(lastParse.startAt); } catch (_e) {}
      resetForm();
      if (window.hideModal) window.hideModal("#agenda-quick-add");
    }

    function resetForm() {
      input.value = "";
      lastParse = null;
      previewWrap.classList.add("hidden");
      errorEl.classList.add("hidden");
      submitBtn.disabled = true;
    }

    function openAdvanced() {
      // Close this modal, then open the existing advanced add modal.
      // Prefill what we already parsed so the user doesn't retype.
      if (window.hideModal) window.hideModal("#agenda-quick-add");
      const prefillName = lastParse?.ok ? lastParse.name : input.value.trim();
      // The advanced modal expects a date string (YYYY-MM-DD) and
      // HH:MM time strings. Build those from lastParse when available,
      // otherwise let the modal use its own defaults.
      if (lastParse?.ok && window.__agendaAddModalPrefill) {
        const pad = (n) => String(n).padStart(2, "0");
        const s = lastParse.hints.startDate;
        const e = lastParse.hints.endDate;
        const dateISO = `${s.getFullYear()}-${pad(s.getMonth() + 1)}-${pad(s.getDate())}`;
        // For all-day, hand the advanced modal the INCLUSIVE last day —
        // that's what its `alldayEnd` input expects (it then maps back to
        // Google's exclusive next-day midnight on submit).
        const inclusiveEnd = new Date(e.getTime() - 1);
        const alldayEndISO = `${inclusiveEnd.getFullYear()}-${pad(inclusiveEnd.getMonth() + 1)}-${pad(inclusiveEnd.getDate())}`;
        window.__agendaAddModalPrefill({
          name:       prefillName,
          kind:       "event",
          date:       dateISO,
          startTime:  `${pad(s.getHours())}:${pad(s.getMinutes())}`,
          endTime:    `${pad(e.getHours())}:${pad(e.getMinutes())}`,
          location:   lastParse.location || "",
          allDay:     !!lastParse.allDay,
          alldayEnd:  alldayEndISO,
        });
      } else {
        if (window.showModal) window.showModal("#agenda-add-modal");
        // Drop whatever raw text the user had into the advanced form's
        // name field so they keep their typing.
        const advForm = document.querySelector(".agenda-add-form");
        const advName = advForm?.querySelector(".add-name");
        if (advName && prefillName) advName.value = prefillName;
      }
    }

    // Wire events ---------------------------------------------------------
    input.addEventListener("input", paintPreview);

    form.addEventListener("submit", (e) => { e.preventDefault(); submit(); });

    advBtn.addEventListener("click", () => openAdvanced());

    examples.forEach((btn) => {
      btn.addEventListener("click", () => {
        input.value = btn.textContent.trim();
        paintPreview();
        input.focus();
      });
    });

    // On open: clear stale state + focus input. jQuery is used by the
    // app's modal lifecycle so the event hook matches the other modals.
    if (window.jQuery) {
      window.jQuery(modal).on("modal.shown", () => {
        resetForm();
        // Focus the input on the next tick so iOS Safari's keyboard
        // actually pops up (focus-during-show-animation gets dropped).
        setTimeout(() => input.focus(), 50);
      });
    }
  });
})();
