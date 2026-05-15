(function () {
  const QUEUE_KEY = "agendaPendingOps:v3";

  // ---------- helpers ----------
  function $(sel, root = document) { return root.querySelector(sel); }
  function $$(sel, root = document) { return Array.from(root.querySelectorAll(sel)); }

  function el(html) {
    const t = document.createElement("template");
    t.innerHTML = html.trim();
    return t.content.firstElementChild;
  }

  function escapeHtml(s) {
    return String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));
  }
  function escapeAttr(s) { return escapeHtml(s).replace(/'/g, "&#39;"); }

  function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
  }

  // Match the server-side `strftime("%-l:%M%P")` format exactly so a JS re-render
  // (via Monitor broadcast) produces the same text as the ERB partial — no
  // locale-dependent "9:00 AM" vs "9:00am" disparity between renders.
  function fmtTime(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    let h = d.getHours();
    const m = d.getMinutes();
    const ampm = h >= 12 ? "pm" : "am";
    h = h % 12;
    if (h === 0) h = 12;
    return `${h}:${String(m).padStart(2, "0")}${ampm}`;
  }

  function toast(msg, kind) {
    const cls = kind === "error" ? "agenda-toast error" : "agenda-toast";
    let node = $(".agenda-toast");
    if (!node) {
      node = el(`<div class="${cls}"></div>`);
      document.body.appendChild(node);
    }
    node.className = cls;
    node.textContent = msg;
    requestAnimationFrame(() => node.classList.add("show"));
    clearTimeout(node.__t);
    node.__t = setTimeout(() => node.classList.remove("show"), 2400);
  }

  function ajax(method, url, body) {
    return fetch(url, {
      method,
      credentials: "same-origin",
      headers:     {
        "Content-Type":     "application/json",
        "Accept":           "application/json",
        "X-CSRF-Token":     csrfToken(),
        "X-Requested-With": "XMLHttpRequest",
      },
      body: body ? JSON.stringify(body) : undefined,
    }).then((res) => {
      if (!res.ok) throw new Error(`${method} ${url} → ${res.status}`);
      return res;
    });
  }

  // ---------- offline queue ----------
  function getQueue() {
    try { return JSON.parse(localStorage.getItem(QUEUE_KEY) || "[]"); }
    catch (_) { return []; }
  }
  function saveQueue(q) { localStorage.setItem(QUEUE_KEY, JSON.stringify(q)); }
  function enqueue(op) {
    const q = getQueue();
    const idx = q.findIndex((p) => p.dedup_key === op.dedup_key);
    if (idx >= 0) q[idx] = op;
    else q.push(op);
    saveQueue(q);
  }
  function processQueue() {
    const q = getQueue();
    if (q.length === 0) return Promise.resolve();
    saveQueue([]);
    return q.reduce(
      (p, op) => p.then(() => ajax(op.method, op.url, op.body).catch(() => enqueue(op))),
      Promise.resolve(),
    );
  }
  window.addEventListener("online", processQueue);

  // ---------- monitor-payload rendering ----------
  // Mirror the server-side `_item.html.erb` partial — every attribute, class,
  // and child element here must match the ERB so that a page rendered cold and
  // a page re-rendered after a Monitor broadcast look + behave identically.
  function renderItem(item, opts = {}) {
    const preview = opts.preview;
    const cls = [
      "agenda-item",
      `kind-${item.kind}`,
      item.crossed_out ? "crossed-out" : "",
      item.recurring ? "recurring" : "",
      item.phantom ? "phantom" : "",
      preview ? "preview" : "",
    ].filter(Boolean).join(" ");

    const url = `/agenda_items/${encodeURIComponent(item.id)}`;
    const color = item.color || "";
    const agendaColor = item.agenda_color || "";
    const timeStr = item.kind === "event" && item.end_at
      ? `${fmtTime(item.start_at)}<span class="time-sep">–</span>${fmtTime(item.end_at)}`
      : fmtTime(item.start_at);
    const checkboxId = `agenda_item_${item.id}`;
    const editable = !preview && item.editable !== false;
    const readonly = !preview && !editable;
    const check = editable ? `
      <input type="checkbox" class="agenda-item-check" id="${checkboxId}"
        ${item.completed_at ? "checked" : ""}
        data-checked-url="${url}">` : "";
    const loc = item.location ? `<span class="agenda-item-loc"><i class="fa fa-map-marker"></i> ${escapeHtml(item.location)}</span>` : "";
    const badge = item.recurring ? `<span class="agenda-item-badge"><i class="fa fa-refresh"></i></span>` : "";
    const editBtn = editable ? `<button type="button" class="agenda-item-edit" data-edit-item aria-label="Edit"><i class="fa fa-pencil"></i></button>` : "";
    const scheduleAttr = item.schedule ? escapeAttr(JSON.stringify(item.schedule)) : "";
    // <label for="..."> when interactive (toggles checkbox on tap); plain div
    // when preview or readonly (no checkbox to link to).
    const bodyOpen = editable
      ? `<label for="${checkboxId}" class="agenda-item-body">`
      : `<div class="agenda-item-body">`;
    const bodyClose = editable ? `</label>` : `</div>`;
    const rowReadonlyAttrs = readonly ? "data-edit-item data-readonly" : "";
    const cls2 = cls + (readonly ? " readonly" : "");

    return el(`
      <div class="${cls2}"
           style="--item-color: ${color}; --agenda-color: ${agendaColor};"
           title="${escapeAttr(item.agenda_name || "")}"
           ${rowReadonlyAttrs}
           data-item-id="${item.id}"
           data-item-url="${url}"
           data-phantom="${!!item.phantom}"
           data-recurring="${!!item.recurring}"
           data-kind="${item.kind}"
           data-color="${color}"
           data-agenda-id="${item.agenda_id}"
           data-agenda-name="${escapeAttr(item.agenda_name || "")}"
           data-agenda-color="${agendaColor}"
           data-start-at="${item.start_at}"
           data-end-at="${item.end_at || ""}"
           data-name="${escapeAttr(item.name)}"
           data-notes="${escapeAttr(item.notes || "")}"
           data-location="${escapeAttr(item.location || "")}"
           data-trigger-expression="${escapeAttr(item.trigger_expression || "")}"
           data-schedule="${scheduleAttr}">
        ${check}
        ${bodyOpen}
          <span class="agenda-item-dot" aria-hidden="true"></span>
          <span class="agenda-item-time">${timeStr}</span>
          <span class="agenda-item-text">
            <span class="agenda-item-name">${escapeHtml(item.name)}</span>
            ${loc}
          </span>
          ${badge}
        ${bodyClose}
        ${editBtn}
      </div>
    `);
  }


  function replaceSection(container, items, opts = {}) {
    if (!container) return;
    container.innerHTML = "";
    if (items.length === 0) {
      const empty = opts.preview ? "Nothing scheduled yet." : "Nothing scheduled.";
      const muted = opts.preview ? "muted" : "";
      container.appendChild(el(`<div class="agenda-empty ${muted}">${empty}</div>`));
      return;
    }
    items.forEach((item) => container.appendChild(renderItem(item, opts)));
  }

  function applyMonitorData(data) {
    const root = $(".agenda-page");
    if (!root) return;
    if (String(data.date) !== root.dataset.currentDate) return;

    replaceSection($('[data-section="today"]'), data.today || []);
    replaceSection($('[data-section="tomorrow"]'), data.tomorrow || [], { preview: true });

    const carrySection = $(".section-carry");
    if (data.carry_over && data.carry_over.length > 0) {
      if (!carrySection) { window.location.reload(); }
      else replaceSection($(".section-carry .agenda-items"), data.carry_over);
    } else if (carrySection) {
      carrySection.remove();
    }

    // Items just got re-rendered — re-apply the localStorage visibility
    // filter so user's hidden agendas stay hidden after WS refresh.
    applyAgendaVisibility();
  }

  // ---------- shared agenda picker ----------
  // Custom dropdown for the agenda select. Native <select> can't reliably
  // style <option>s (Safari ignores backgrounds entirely), so we render a
  // toggle + floating list where every option carries its agenda color via
  // a dot + tinted row. The hidden input stores the value so submit code
  // keeps reading `.add-agenda-id` unchanged.
  //
  // Returns { value(), setValue(id), close() } for the caller. `onChange` is
  // invoked as (id, color, name) when the user picks an option.
  function bindAgendaPicker(form, onChange) {
    const pick = $(".agenda-pick", form);
    if (!pick) return null;
    const toggle = $(".agenda-pick-toggle", pick);
    const menu = $(".agenda-pick-menu", pick);
    const label = $(".agenda-pick-label", pick);
    const hidden = $(".add-agenda-id", form);
    if (!toggle || !menu || !hidden) return null;

    function applyOption(li, fireChange) {
      if (!li) return;
      const id = li.dataset.id;
      const color = li.dataset.color;
      const name = li.dataset.name;
      hidden.value = id;
      pick.style.setProperty("--picked-agenda-color", color);
      if (label) label.textContent = name;
      $$("li", menu).forEach((other) => {
        const sel = other === li;
        other.classList.toggle("selected", sel);
        if (sel) other.setAttribute("aria-selected", "true");
        else other.removeAttribute("aria-selected");
      });
      if (fireChange && typeof onChange === "function") onChange(id, color, name);
    }

    function positionMenu() {
      const rect = toggle.getBoundingClientRect();
      const vpH = window.innerHeight;
      menu.style.left = `${rect.left}px`;
      menu.style.minWidth = `${rect.width}px`;
      // Open downward by default; flip up if it'd overflow the viewport.
      menu.style.maxHeight = `${Math.min(240, vpH - rect.bottom - 12)}px`;
      const wantsFlip = rect.bottom + 240 > vpH && rect.top > vpH - rect.bottom;
      if (wantsFlip) {
        menu.style.top = "";
        menu.style.bottom = `${vpH - rect.top + 4}px`;
        menu.style.maxHeight = `${Math.min(240, rect.top - 12)}px`;
      } else {
        menu.style.bottom = "";
        menu.style.top = `${rect.bottom + 4}px`;
      }
    }

    function open() {
      menu.classList.remove("hidden");
      toggle.setAttribute("aria-expanded", "true");
      positionMenu();
      // Defer attaching the outside-click listener until after the current
      // click event finishes bubbling — otherwise the click that opened the
      // menu would immediately close it.
      setTimeout(() => {
        document.addEventListener("click", onDocClick);
        document.addEventListener("keydown", onDocKey);
        window.addEventListener("scroll", positionMenu, true);
        window.addEventListener("resize", positionMenu);
      }, 0);
      // Scroll the selected option into view.
      menu.querySelector("li.selected")?.scrollIntoView({ block: "nearest" });
    }
    function close() {
      menu.classList.add("hidden");
      toggle.setAttribute("aria-expanded", "false");
      document.removeEventListener("click", onDocClick);
      document.removeEventListener("keydown", onDocKey);
      window.removeEventListener("scroll", positionMenu, true);
      window.removeEventListener("resize", positionMenu);
    }
    function onDocClick(e) {
      if (!pick.contains(e.target)) close();
    }
    function onDocKey(e) {
      if (e.key === "Escape") {
        e.stopPropagation(); // don't close the modal
        close();
        toggle.focus();
      }
    }

    toggle.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      if (menu.classList.contains("hidden")) open();
      else close();
    });

    menu.addEventListener("click", (e) => {
      const li = e.target.closest("li[data-id]");
      if (!li) return;
      e.stopPropagation();
      applyOption(li, true);
      close();
      toggle.focus();
    });

    return {
      value: () => hidden.value,
      setValue: (id) => {
        const li = menu.querySelector(`li[data-id="${CSS.escape(String(id))}"]`);
        if (li) applyOption(li, false); // setValue is programmatic — no onChange
      },
      close,
    };
  }

  // ---------- shared schedule fields ----------
  // Encapsulates the recurrence/days/until/count UI used by BOTH the add modal
  // and the edit modal. Returns an interface for prefilling, building payloads,
  // and clearing state.
  function bindScheduleFields(form) {
    const weekdaySet = new Set();
    const monthDaySet = new Set();
    const WDAY_KEYS = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"];

    const freqSelect    = $(".add-freq", form);
    const dateInput     = $(".add-date", form);
    const weeklyRow     = $(".add-weekly", form);
    const monthlyRow    = $(".add-monthly", form);
    const customRow     = $(".add-custom", form);
    const monthModeRow  = $(".add-month-mode", form);
    const unitSelect    = $(".add-unit", form);
    const intervalInput = $(".add-interval", form);
    const setPosSelect  = $(".add-set-pos", form);
    const setWdaySelect = $(".add-set-wday", form);
    const monthDayLabel = $(".month-day-label", form);
    const endsField     = $(".add-ends-field", form);
    const endModeSelect = $(".add-end-mode", form);
    const untilInput    = $(".add-until", form);
    const countInput    = $(".add-count", form);

    function syncFreq() {
      if (!freqSelect) return;
      const freq = freqSelect.value;
      weeklyRow?.classList.toggle("hidden", freq !== "weekly");
      monthlyRow?.classList.toggle("hidden", freq !== "monthly");
      customRow?.classList.toggle("hidden", freq !== "custom");
      endsField?.classList.toggle("hidden", freq === "never");
      syncEndMode();
      syncMonthMode();

      if (freq === "weekly" && weekdaySet.size === 0 && dateInput) {
        const key = WDAY_KEYS[localDateFromInput(dateInput.value).getDay()];
        weekdaySet.add(key);
        form.querySelector(`.wd-chip[data-day="${key}"]`)?.classList.add("active");
      }

      if (freq === "monthly" && monthDaySet.size === 0 && dateInput) {
        const dom = String(localDateFromInput(dateInput.value).getDate());
        monthDaySet.add(dom);
        form.querySelector(`.md-chip[data-day="${dom}"]`)?.classList.add("active");
      }
    }

    // "Day X of month" / "The Nth weekday" — only relevant when custom+month.
    function syncMonthMode() {
      if (!monthModeRow || !freqSelect || !unitSelect) return;
      const showMode = freqSelect.value === "custom" && unitSelect.value === "month";
      monthModeRow.classList.toggle("hidden", !showMode);
      if (!showMode || !dateInput) return;

      const ref = localDateFromInput(dateInput.value);
      if (monthDayLabel)  monthDayLabel.textContent = ref.getDate();
      if (setPosSelect)   setPosSelect.value = ordinalPositionForDate(ref);
      if (setWdaySelect)  setWdaySelect.value = WDAY_KEYS[ref.getDay()];
    }

    function syncEndMode() {
      const mode = endModeSelect ? endModeSelect.value : "never";
      untilInput?.classList.toggle("hidden", mode !== "until");
      countInput?.classList.toggle("hidden", mode !== "count");
    }

    // Prefill the schedule UI from a serialized hash (typically from the
    // server's AgendaSchedule#serialize_for_edit).
    //
    // IMPORTANT: do NOT write `data.starts_on` into the date input. The
    // date input is the OCCURRENCE date (in the edit modal) or the new
    // item's date (in the add modal). The schedule's original starts_on
    // must stay separate — overwriting it caused occurrence-scope edits
    // on a future phantom to materialize on the schedule's start date
    // instead of the occurrence date.
    function applySchedule(data) {
      if (!data || typeof data !== "object") return;

      if (data.freq && freqSelect) freqSelect.value = data.freq;

      if (Array.isArray(data.by_day)) {
        weekdaySet.clear();
        $$(".wd-chip", form).forEach((b) => b.classList.remove("active"));
        data.by_day.forEach((d) => {
          const key = String(d).toLowerCase();
          weekdaySet.add(key);
          form.querySelector(`.wd-chip[data-day="${key}"]`)?.classList.add("active");
        });
      }
      if (Array.isArray(data.by_month_day)) {
        monthDaySet.clear();
        $$(".md-chip", form).forEach((b) => b.classList.remove("active"));
        data.by_month_day.forEach((d) => {
          const key = String(d);
          monthDaySet.add(key);
          form.querySelector(`.md-chip[data-day="${key}"]`)?.classList.add("active");
        });
      }
      if (data.interval && intervalInput) intervalInput.value = data.interval;
      if (data.unit && unitSelect) unitSelect.value = data.unit;
      if (data.by_set_pos != null) {
        if (setPosSelect) setPosSelect.value = String(data.by_set_pos);
        const radio = form.querySelector("input[type='radio'][value='nth-weekday']");
        if (radio) radio.checked = true;
        if (data.by_day?.[0] && setWdaySelect) setWdaySelect.value = data.by_day[0];
      }
      if (data.occurrence_count) {
        if (endModeSelect) endModeSelect.value = "count";
        if (countInput) countInput.value = data.occurrence_count;
      } else if (data.until_on) {
        if (endModeSelect) endModeSelect.value = "until";
        if (untilInput) untilInput.value = data.until_on;
      } else if (endModeSelect) {
        endModeSelect.value = "never";
      }

      syncFreq();
      syncEndMode();
      syncMonthMode();
    }

    // Assemble the full agenda_schedule payload from current form state.
    // `startsOn` (optional) lets the caller preserve the schedule's original
    // start date instead of using the form's date input — important for
    // edit-series flows so editing the rule doesn't shift the schedule's
    // historical start to the occurrence's date.
    function buildSchedulePayload({ name, kind, color, startTime, endTime, date, triggerExpression, startsOn }) {
      const freq = freqSelect.value;
      const recurrence = { freq };

      if (freq === "weekly") recurrence.by_day = Array.from(weekdaySet);
      if (freq === "monthly") {
        const days = Array.from(monthDaySet).map((s) => parseInt(s, 10)).filter((n) => !Number.isNaN(n));
        if (days.length) recurrence.by_month_day = days;
      }
      if (freq === "custom") {
        recurrence.interval = parseInt(intervalInput?.value, 10) || 1;
        recurrence.unit = unitSelect?.value || "day";
        if (recurrence.unit === "month") {
          const mode = form.querySelector("input.add-month-mode-radio:checked")?.value;
          if (mode === "nth-weekday") {
            recurrence.by_set_pos = parseInt(setPosSelect.value, 10);
            recurrence.by_day = [setWdaySelect.value];
          }
        }
      }

      const duration = kind === "event" ? Math.max(15, minutesBetween(startTime, endTime)) : null;
      const endMode = endModeSelect ? endModeSelect.value : "never";
      const untilOn = endMode === "until" && untilInput?.value ? untilInput.value : null;
      const occurrenceCount = endMode === "count" && countInput?.value
        ? Math.max(1, parseInt(countInput.value, 10))
        : null;

      return {
        name,
        kind,
        color,
        start_time:         startTime,
        duration_minutes:   duration,
        starts_on:          startsOn || date,
        until_on:           untilOn,
        occurrence_count:   occurrenceCount,
        trigger_expression: triggerExpression,
        recurrence,
      };
    }

    function resetChips() {
      weekdaySet.clear();
      monthDaySet.clear();
      $$(".wd-chip", form).forEach((b) => b.classList.remove("active"));
      $$(".md-chip", form).forEach((b) => b.classList.remove("active"));
    }

    // Bind handlers.
    freqSelect?.addEventListener("change", syncFreq);
    unitSelect?.addEventListener("change", syncMonthMode);
    dateInput?.addEventListener("change", syncMonthMode);
    endModeSelect?.addEventListener("change", syncEndMode);

    $$(".wd-chip", form).forEach((btn) => {
      btn.addEventListener("click", () => {
        const key = btn.dataset.day;
        if (weekdaySet.has(key)) { weekdaySet.delete(key); btn.classList.remove("active"); }
        else { weekdaySet.add(key); btn.classList.add("active"); }
      });
    });

    $$(".md-chip", form).forEach((btn) => {
      btn.addEventListener("click", () => {
        const key = btn.dataset.day;
        if (monthDaySet.has(key)) { monthDaySet.delete(key); btn.classList.remove("active"); }
        else { monthDaySet.add(key); btn.classList.add("active"); }
      });
    });

    syncFreq();

    return { weekdaySet, monthDaySet, syncFreq, syncEndMode, syncMonthMode, applySchedule, buildSchedulePayload, resetChips };
  }

  // Parse a YYYY-MM-DD value as a LOCAL date.
  function localDateFromInput(value) {
    if (!value) return new Date();
    const parts = value.split("-").map(Number);
    if (parts.length !== 3 || parts.some(Number.isNaN)) return new Date(value);
    return new Date(parts[0], parts[1] - 1, parts[2]);
  }

  // "1".."4" or "-1" — defaults to "-1" (last) when the date is the last
  // occurrence of its weekday in its month.
  function ordinalPositionForDate(date) {
    const next = new Date(date);
    next.setDate(date.getDate() + 7);
    if (next.getMonth() !== date.getMonth()) return "-1";
    return String(Math.min(4, Math.ceil(date.getDate() / 7)));
  }

  function minutesBetween(start, end) {
    if (!start || !end) return 60;
    const [sh, sm] = start.split(":").map(Number);
    const [eh, em] = end.split(":").map(Number);
    return Math.max(15, (eh * 60 + em) - (sh * 60 + sm));
  }

  function initAddModal(modal) {
    const form = $(".agenda-add-form", modal);
    if (!form) return;

    let activeKind = "task";
    const sched = bindScheduleFields(form);

    const nameInput = $(".add-name", form);
    const startInput = $(".add-start", form);
    const endInput = $(".add-end", form);
    const endField = $(".add-end-field", form);
    const dateInput = $(".add-date", form);
    const colorInput = $(".add-color", form);
    const colorHexPreview = $(".color-hex-preview", form);
    const colorSwatch = $(".color-swatch", form);

    function paintColor(c) {
      if (!c) return;
      if (colorSwatch) colorSwatch.style.background = c;
      if (colorHexPreview) colorHexPreview.textContent = c.toUpperCase();
    }

    // When the user picks a different agenda, default the item color to that
    // agenda's color (unless they've manually touched the color picker).
    let colorTouched = false;
    const agendaPicker = bindAgendaPicker(form, (id, color) => {
      if (colorTouched || !colorInput || !color) return;
      colorInput.value = color;
      paintColor(color);
    });

    function syncKind() {
      $$(".kind-btn", form).forEach((b) => b.classList.toggle("active", b.dataset.kind === activeKind));
      endField.classList.toggle("hidden", activeKind !== "event");
      $(".add-trigger-field", form)?.classList.toggle("hidden", activeKind !== "trigger");
    }

    function resetForm() {
      form.reset();
      activeKind = "task";
      sched.resetChips();
      dateInput.value = form.dataset.defaultDate;
      // Re-sync the agenda picker's visual state with whatever the hidden
      // input reset to (the server-rendered default), since the picker holds
      // its own label/dot/selected state outside of native form semantics.
      const currentId = agendaPicker?.value();
      if (currentId) agendaPicker.setValue(currentId);
      colorTouched = false;
      syncKind();
      sched.syncFreq();
    }

    $$(".kind-btn", form).forEach((btn) => {
      btn.addEventListener("click", () => { activeKind = btn.dataset.kind; syncKind(); });
    });

    if (colorInput) {
      colorInput.addEventListener("input", () => {
        colorTouched = true;
        paintColor(colorInput.value);
      });
    }

    form.addEventListener("submit", (e) => { e.preventDefault(); submit(); });

    if (window.jQuery) {
      window.jQuery(modal).on("modal.shown", () => {
        applyDefaultStartTime();
        nameInput.focus();
      });
    }

    // Default the start time to the top of the next hour when the date is
    // today. For other days, fall back to 09:00. Triggered on every open so
    // the default reflects the time the user actually opened the modal.
    function applyDefaultStartTime() {
      const now = new Date();
      const pad = (n) => String(n).padStart(2, "0");
      const todayStr = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;

      if (dateInput.value === todayStr) {
        const atTop = now.getMinutes() === 0 && now.getSeconds() === 0;
        const h = atTop ? now.getHours() : (now.getHours() + 1) % 24;
        const startStr = `${pad(h)}:00`;
        const endStr = `${pad((h + 1) % 24)}:00`;
        startInput.value = startStr;
        endInput.value = endStr;
      } else {
        startInput.value = "09:00";
        endInput.value = "10:00";
      }
    }

    function submit() {
      const name = nameInput.value.trim();
      if (!name) { nameInput.focus(); return; }

      const date = dateInput.value || form.dataset.defaultDate;
      const startTime = startInput.value || "09:00";
      const endTime = endInput.value || "10:00";
      const startAt = `${date}T${startTime}`;
      const endAt = activeKind === "event" ? `${date}T${endTime}` : null;
      const freq = $(".add-freq", form).value;
      const color = colorInput?.value || null;
      const triggerExpression = activeKind === "trigger"
        ? ($(".add-trigger-expression", form)?.value || "").trim() || null
        : null;

      const closeModal = () => {
        if (window.hideModal) window.hideModal("#agenda-add-modal");
        resetForm();
      };

      const location = $(".add-location", form)?.value || null;
      const notes = $(".add-notes", form)?.value || null;

      const agendaId = agendaPicker?.value() ? parseInt(agendaPicker.value(), 10) : null;
      if (!agendaId) { toast("Pick an agenda", "error"); return; }

      if (freq === "never") {
        ajax("POST", form.dataset.itemUrl, {
          agenda_item: {
            agenda_id:          agendaId,
            name,
            kind:               activeKind,
            start_at:           startAt,
            end_at:             endAt,
            color:              color,
            location,
            notes,
            trigger_expression: triggerExpression,
          },
        })
          .then(() => { closeModal(); toast("Added"); })
          .catch((err) => { console.error(err); toast("Couldn't add — try again", "error"); });
        return;
      }

      const schedulePayload = sched.buildSchedulePayload({
        name, kind: activeKind, color,
        startTime, endTime, date, triggerExpression,
      });
      schedulePayload.agenda_id = agendaId;
      schedulePayload.location = location;
      schedulePayload.notes = notes;
      ajax("POST", form.dataset.scheduleUrl, { agenda_schedule: schedulePayload })
        .then(() => { closeModal(); toast("Added"); })
        .catch((err) => { console.error(err); toast("Couldn't add — try again", "error"); });
    }

    syncKind();
  }

  // ---------- checkbox toggle (with offline queue) ----------
  function initChecks(root) {
    root.addEventListener("change", (e) => {
      const cb = e.target.closest(".agenda-item-check");
      if (!cb) return;
      const url = cb.dataset.checkedUrl;
      const op = {
        dedup_key: `check:${url}`,
        url,
        method:    "PATCH",
        body:      { agenda_item: { completed_at: cb.checked ? "now" : "" } },
      };
      ajax(op.method, op.url, op.body).catch(() => { enqueue(op); toast("Saved offline — will sync", "error"); });
      cb.closest(".agenda-item")?.classList.toggle("crossed-out", cb.checked);
    });
  }

  // ---------- edit modal ----------
  function initEdit(root) {
    const modal = $("#agenda-item-edit");
    if (!modal) return;
    const form = $(".agenda-edit-form", modal);
    const sched = bindScheduleFields(form);
    const deleteBtn = $(".add-delete", form);
    const saveBtn = $(".add-save", form);

    let activeKind = "task";
    let currentRecurring = false;
    let currentScheduleData = null;

    function syncKind() {
      $$(".kind-btn", form).forEach((b) => b.classList.toggle("active", b.dataset.kind === activeKind));
      $(".add-end-field", form).classList.toggle("hidden", activeKind !== "event");
      $(".add-trigger-field", form)?.classList.toggle("hidden", activeKind !== "trigger");
    }

    $$(".kind-btn", form).forEach((btn) => {
      btn.addEventListener("click", () => { activeKind = btn.dataset.kind; syncKind(); });
    });

    // Wire the custom agenda picker. No item-color cascade here — the user
    // is editing a specific item that already has its own color.
    const editAgendaPicker = bindAgendaPicker(form);

    // Only elements explicitly marked data-edit-item respond to clicks.
    // Editable rows: pencil carries data-edit-item → opens edit modal.
    //   (The <label> body toggles the checkbox natively — never reaches here
    //    because the label/checkbox interaction doesn't bubble as a click on
    //    data-edit-item.)
    // Readonly rows: the whole row carries data-edit-item + data-readonly →
    //   opens the details modal instead.
    root.addEventListener("click", (e) => {
      const editBtn = e.target.closest("[data-edit-item]");
      if (!editBtn) return;
      e.preventDefault();
      e.stopPropagation();
      const dataEl = editBtn.closest("[data-item-id]");
      if (!dataEl || dataEl.classList.contains("preview")) return;
      if (dataEl.hasAttribute("data-readonly")) {
        openDetailsModal(dataEl);
      } else {
        openModal(dataEl);
      }
    });

    function openModal(item) {
      const d = item.dataset;
      $(".add-item-id", form).value = d.itemId;
      $(".add-name", form).value = d.name;
      if (d.agendaId) editAgendaPicker?.setValue(d.agendaId);

      activeKind = d.kind || "task";
      syncKind();

      // Item's start_at is a UTC ISO; split into local date + time-of-day.
      const [startDate, startTime] = splitIsoToDateAndTime(d.startAt);
      const [, endTime] = splitIsoToDateAndTime(d.endAt);
      $(".add-date", form).value = startDate;
      $(".add-start", form).value = startTime || "09:00";
      $(".add-end", form).value = endTime || "10:00";

      $(".add-location", form).value = d.location || "";
      $(".add-notes", form).value = d.notes || "";
      $(".add-trigger-expression", form).value = d.triggerExpression || "";

      const colorEl = $(".add-color", form);
      const colorHex = $(".color-hex-preview", form);
      const colorSwatchEl = $(".color-swatch", form);
      const colorValue = d.color || "#0160FF";
      if (colorEl) colorEl.value = colorValue;
      if (colorHex) colorHex.textContent = colorValue.toUpperCase();
      if (colorSwatchEl) colorSwatchEl.style.background = colorValue;

      currentRecurring = d.recurring === "true";
      $(".add-scope-field", form).classList.toggle("hidden", !currentRecurring);

      // Recurring items default to "this and all future" — that's the more
      // common edit and matches the user's stated preference.
      const seriesRadio = form.querySelector("input[name='scope'][value='series']");
      const occRadio = form.querySelector("input[name='scope'][value='occurrence']");
      if (currentRecurring) {
        if (seriesRadio) seriesRadio.checked = true;
      } else if (occRadio) {
        occRadio.checked = true;
      }

      // Prefill schedule fields for recurring items from data-schedule JSON.
      // For non-recurring items, reset the schedule UI to a clean state.
      sched.resetChips();
      currentScheduleData = null;
      if (currentRecurring && d.schedule && d.schedule !== "null") {
        try { currentScheduleData = JSON.parse(d.schedule); } catch (_) { currentScheduleData = null; }
      }
      if (currentScheduleData) {
        sched.applySchedule(currentScheduleData);
      } else {
        const freqSelect = $(".add-freq", form);
        if (freqSelect) freqSelect.value = "never";
        sched.syncFreq();
      }

      form.dataset.itemUrl = d.itemUrl;
      updateDeleteLabel();
      updateSaveLabel();
      if (window.showModal) window.showModal("#agenda-item-edit");
    }

    function splitIsoToDateAndTime(iso) {
      if (!iso) return ["", ""];
      const local = isoToLocalInput(iso);
      return local.split("T");
    }

    function closeModal() {
      if (window.hideModal) window.hideModal("#agenda-item-edit");
    }

    function currentScope() {
      return form.querySelector("input[name='scope']:checked")?.value || "occurrence";
    }

    function updateDeleteLabel() {
      if (!deleteBtn) return;
      if (!currentRecurring) {
        deleteBtn.textContent = "Delete";
      } else if (currentScope() === "series") {
        deleteBtn.textContent = "Delete All";
      } else {
        deleteBtn.textContent = "Delete One";
      }
    }

    function updateSaveLabel() {
      if (!saveBtn) return;
      if (!currentRecurring) {
        saveBtn.textContent = "Save";
      } else if (currentScope() === "series") {
        saveBtn.textContent = "Save All";
      } else {
        saveBtn.textContent = "Save One";
      }
    }

    $$("input[name='scope']", form).forEach((radio) => {
      radio.addEventListener("change", () => {
        updateDeleteLabel();
        updateSaveLabel();
      });
    });

    const colorInput = $(".add-color", form);
    if (colorInput) {
      colorInput.addEventListener("input", () => {
        const v = colorInput.value;
        const hex = $(".color-hex-preview", form);
        if (hex) hex.textContent = v.toUpperCase();
        const sw = $(".color-swatch", form);
        if (sw) sw.style.background = v;
      });
    }

    form.addEventListener("submit", (e) => {
      e.preventDefault();
      const scope = currentScope();
      const date = $(".add-date", form).value;
      const startTime = $(".add-start", form).value || "09:00";
      const endTime = $(".add-end", form).value || "10:00";
      const startAt = `${date}T${startTime}`;
      const endAt = activeKind === "event" ? `${date}T${endTime}` : null;
      const triggerExpression = activeKind === "trigger"
        ? ($(".add-trigger-expression", form).value || null)
        : null;
      const color = $(".add-color", form)?.value || null;

      const agendaIdRaw = editAgendaPicker?.value();
      const agendaId = agendaIdRaw ? parseInt(agendaIdRaw, 10) : null;

      const payload = {
        scope,
        agenda_item: {
          agenda_id:          agendaId,
          name:               $(".add-name", form).value,
          kind:               activeKind,
          color:              color,
          start_at:           startAt,
          end_at:             endAt,
          location:           $(".add-location", form).value,
          notes:              $(".add-notes", form).value,
          trigger_expression: triggerExpression,
        },
      };

      // When editing the series, send a full schedule payload so the user
      // can change recurrence / days / until / count, not just the per-item
      // fields the controller can derive. Preserve the schedule's original
      // starts_on rather than overwriting it with this occurrence's date.
      //
      // location + notes have to be merged in explicitly — buildSchedulePayload
      // doesn't include them (it's shared with the add modal which appends them
      // separately). Without these, a series edit silently dropped any
      // location/notes change.
      if (scope === "series" && currentRecurring) {
        payload.agenda_schedule = sched.buildSchedulePayload({
          name: payload.agenda_item.name,
          kind: activeKind,
          color,
          startTime, endTime, date, triggerExpression,
          startsOn: currentScheduleData?.starts_on,
        });
        payload.agenda_schedule.location = payload.agenda_item.location;
        payload.agenda_schedule.notes = payload.agenda_item.notes;
      }

      // Mark the targeted item as pending-save so the user sees something is
      // happening; do NOT change displayed values. The actual update arrives
      // via the server's WS broadcast — that's the authoritative signal.
      const itemEl = findItemEl($(".add-item-id", form).value);
      itemEl?.classList.add("is-pending");

      ajax("PATCH", form.dataset.itemUrl, payload)
        .then(() => { closeModal(); toast("Saved"); })
        .catch((err) => {
          console.error(err);
          itemEl?.classList.remove("is-pending");
          toast("Couldn't save — try again", "error");
        });
    });

    deleteBtn.addEventListener("click", () => {
      const scope = currentScope();
      const label = deleteBtn.textContent;
      if (!window.confirm(`${label} — are you sure?`)) return;

      // Show a "pending delete" visual hint. Don't actually remove the item —
      // the server's WS broadcast is the source of truth; once it arrives,
      // refreshView() re-renders and the item disappears (or stays, on error).
      const itemEl = findItemEl($(".add-item-id", form).value);
      itemEl?.classList.add("is-pending-delete");

      ajax("DELETE", `${form.dataset.itemUrl}?scope=${scope}`)
        .then(() => { closeModal(); toast("Deleted"); })
        .catch((err) => {
          console.error(err);
          itemEl?.classList.remove("is-pending-delete");
          toast("Couldn't delete — try again", "error");
        });
    });

    function findItemEl(id) {
      if (!id) return null;
      return document.querySelector(`[data-item-id="${CSS.escape(id)}"]`);
    }
  }

  function isoToLocalInput(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  // ---------- calendar month view ----------
  // Click semantics:
  //   - .cal-item   → handled by initEdit (data-edit-item attribute)
  //   - .cal-day-num → native <a> navigates to the day view
  //   - elsewhere in .cal-day → open Add modal pre-filled for that date
  function initCalendarPage(root) {
    root.addEventListener("click", (e) => {
      if (e.target.closest(".cal-item")) return;     // item click handled elsewhere
      if (e.target.closest(".cal-day-num")) return;  // let the link navigate

      const dayCell = e.target.closest(".cal-day[data-date]");
      if (!dayCell) return;
      e.preventDefault();
      e.stopPropagation();
      openAddModalForDate(dayCell.dataset.date);
    });

    // Keyboard accessibility — Enter/Space on a focused cal-day opens the
    // add modal for that day.
    root.addEventListener("keydown", (e) => {
      if (e.key !== "Enter" && e.key !== " ") return;
      const dayCell = e.target.closest(".cal-day[data-date]");
      if (!dayCell || e.target !== dayCell) return;
      e.preventDefault();
      openAddModalForDate(dayCell.dataset.date);
    });
  }

  // ---------- agenda visibility filter (localStorage-backed) ----------
  // Lets the user uncheck individual agendas to hide their items in the
  // current view. State persists across reloads under "agendaHidden:v1".
  // Also applies to calendar's `.cal-item` rows since they share the same
  // data-agenda-id attribute.
  const AGENDA_HIDDEN_KEY = "agendaHidden:v1";

  function getHiddenAgendas() {
    try {
      const raw = JSON.parse(localStorage.getItem(AGENDA_HIDDEN_KEY) || "[]");
      return Array.isArray(raw) ? raw.map(String) : [];
    } catch (_) { return []; }
  }
  function saveHiddenAgendas(ids) {
    localStorage.setItem(AGENDA_HIDDEN_KEY, JSON.stringify(ids));
  }
  function applyAgendaVisibility() {
    const hidden = new Set(getHiddenAgendas());
    document.querySelectorAll("[data-agenda-id]").forEach((el) => {
      // Only target item rows (.agenda-item) and calendar buttons (.cal-item).
      // Skip data-edit-item buttons that aren't item rows.
      if (!el.classList.contains("agenda-item") && !el.classList.contains("cal-item")) return;
      el.classList.toggle("hidden-by-filter", hidden.has(el.dataset.agendaId));
    });
  }

  function initAgendaFilter() {
    const btn = document.querySelector(".agenda-filter-btn");
    const panel = document.querySelector(".agenda-filter-panel");
    if (!btn || !panel) return;

    // Sync each checkbox with the persisted hidden set.
    const hidden = new Set(getHiddenAgendas());
    panel.querySelectorAll("input[type=checkbox][data-agenda-id]").forEach((cb) => {
      cb.checked = !hidden.has(cb.dataset.agendaId);
    });
    applyAgendaVisibility();

    function open() {
      panel.classList.remove("hidden");
      btn.setAttribute("aria-expanded", "true");
      setTimeout(() => document.addEventListener("click", outside), 0);
    }
    function close() {
      panel.classList.add("hidden");
      btn.setAttribute("aria-expanded", "false");
      document.removeEventListener("click", outside);
    }
    function outside(e) {
      if (panel.contains(e.target) || btn.contains(e.target)) return;
      close();
    }

    btn.addEventListener("click", (e) => {
      e.stopPropagation();
      panel.classList.contains("hidden") ? open() : close();
    });

    panel.addEventListener("change", (e) => {
      const cb = e.target.closest("input[type=checkbox][data-agenda-id]");
      if (!cb) return;
      const id = cb.dataset.agendaId;
      let next = getHiddenAgendas();
      if (cb.checked) {
        next = next.filter((x) => x !== id);
      } else if (!next.includes(id)) {
        next.push(id);
      }
      saveHiddenAgendas(next);
      applyAgendaVisibility();
    });
  }

  // Read-only details modal — opened when a viewer (no edit permission)
  // taps an item. Populates the static layout from the item's data-* attrs.
  function openDetailsModal(dataEl) {
    const modal = document.getElementById("agenda-item-details");
    if (!modal) return;
    const d = dataEl.dataset;
    const set = (sel, val) => {
      const node = modal.querySelector(sel);
      if (node) node.textContent = val || "";
    };
    const dot = modal.querySelector("[data-agenda-color-target]");
    if (dot) dot.style.background = d.agendaColor || "";
    set("[data-agenda-name-target]", d.agendaName);
    set("[data-name-target]", d.name);

    // Time / date line. Show "Mon, May 14 · 9:00am – 10:00am" for events,
    // "Mon, May 14 · 9:00am" otherwise.
    const start = d.startAt ? new Date(d.startAt) : null;
    const end = d.endAt ? new Date(d.endAt) : null;
    const dayLabel = start ? start.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" }) : "";
    let timeLabel = start ? fmtTime(d.startAt) : "";
    if (d.kind === "event" && end) timeLabel += ` – ${fmtTime(d.endAt)}`;
    set("[data-when-target]", `${dayLabel}${timeLabel ? " · " + timeLabel : ""}`);

    const locRow = modal.querySelector("[data-loc-row]");
    if (locRow) {
      const hasLoc = !!(d.location && d.location.length);
      locRow.classList.toggle("hidden", !hasLoc);
      set("[data-loc-target]", d.location);
    }

    const recurringRow = modal.querySelector("[data-recurring-row]");
    if (recurringRow) {
      const isRecurring = d.recurring === "true";
      recurringRow.classList.toggle("hidden", !isRecurring);
      set("[data-recurring-target]", isRecurring ? "Recurring" : "");
    }

    const notesRow = modal.querySelector("[data-notes-row]");
    if (notesRow) {
      const hasNotes = !!(d.notes && d.notes.length);
      notesRow.classList.toggle("hidden", !hasNotes);
      set("[data-notes-target]", d.notes);
    }

    if (window.showModal) window.showModal("#agenda-item-details");
  }

  function openAddModalForDate(dateStr) {
    const modal = $("#agenda-add-modal");
    if (!modal) return;
    const dateInput = modal.querySelector(".add-date");
    if (dateInput && dateStr) dateInput.value = dateStr;
    if (window.showModal) window.showModal("#agenda-add-modal");
  }

  // ---------- monitor subscription ----------
  function subscribeMonitor() {
    if (typeof window.Monitor === "undefined") {
      setTimeout(subscribeMonitor, 100);
      return;
    }
    // Monitor.subscribe() always fires `disconnected` synchronously if the
    // ActionCable socket hasn't opened yet — true on every page load. Delay
    // showing the banner so the typical sub-second reconnect is swallowed and
    // we only surface a real outage.
    const DISCONNECT_GRACE_MS = 1500;
    let disconnectTimer = null;

    window.Monitor.subscribe("agenda", {
      connected: function () {
        clearTimeout(disconnectTimer);
        disconnectTimer = null;
        $(".agenda-error")?.classList.add("hidden");
        processQueue();
      },
      disconnected: function () {
        clearTimeout(disconnectTimer);
        disconnectTimer = setTimeout(() => {
          $(".agenda-error")?.classList.remove("hidden");
        }, DISCONNECT_GRACE_MS);
      },
      received: function (_data) {
        // Broadcasts go out for every agenda the user has access to. The
        // global views render whatever the current user can see, so any
        // accessible-agenda change is a refresh signal — no filtering by id.
        const root = $(".agenda-page") || $(".agenda-calendar-page");
        if (!root) return;
        refreshView(root);
      },
    });
  }

  // Re-fetches the current view's data so any agenda change shows up
  // regardless of which date or view the user is on. Day view fetches the
  // JSON serialize_for_monitor payload; calendar view reloads (until we have
  // a JSON endpoint for the month grid).
  function refreshView(root) {
    if (root.classList.contains("agenda-calendar-page") || root.classList.contains("agenda-week-page")) {
      // Calendar grids and the 9-section week view aren't worth a custom
      // JSON endpoint yet — page reload renders the fresh state cleanly.
      window.location.reload();
      return;
    }
    const date = root.dataset.currentDate;
    if (!date) return;
    fetch(`/agenda.json?date=${encodeURIComponent(date)}`, {
      credentials: "same-origin",
      headers:     { "Accept": "application/json" },
    })
      .then((res) => (res.ok ? res.json() : null))
      .then((data) => { if (data) applyMonitorData(data); })
      .catch((err) => console.error("agenda refresh failed", err));
  }

  // Day / Week views shown on the plain /agenda (no ?date= override) roll to
  // the new "today" automatically at 3am local. 3am is a more humane day
  // boundary than midnight — people stay up past midnight all the time and
  // don't want their schedule to flip while they're still finishing yesterday.
  // If the user has pinned a specific date in the URL, leave them on it.
  function scheduleAutoDateAdvance(root) {
    if (root.classList.contains("agenda-calendar-page")) return;
    try {
      const url = new URL(window.location.href);
      if (url.searchParams.has("date")) return;
    } catch (_) { /* IE / odd URL — skip */ return; }

    // "Day key" treats hours 0:00–2:59 as still belonging to the previous
    // calendar day, so the perceived day only ticks over at 3am.
    function dayKey() {
      const d = new Date();
      if (d.getHours() < 3) d.setDate(d.getDate() - 1);
      return d.toDateString();
    }
    function msUntilNext3am() {
      const now = new Date();
      const next = new Date(now);
      next.setHours(3, 0, 0, 0);
      if (next <= now) next.setDate(next.getDate() + 1);
      return next - now;
    }

    const loadedDay = dayKey();
    let timer = null;
    function tick() {
      if (dayKey() !== loadedDay) {
        window.location.reload();
      } else {
        // Edge case: timer fired but we're still in the same perceived day
        // (e.g., user loaded at 12:30am — the timer fires at 3am but server
        // already renders today's date). Just reschedule.
        timer = setTimeout(tick, msUntilNext3am());
      }
    }
    timer = setTimeout(tick, msUntilNext3am());

    // Catch the device-sleep case: if the laptop slept through 3am and woke
    // up later, setTimeout may not have fired on time. Re-check on visibility.
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState !== "visible") return;
      if (dayKey() !== loadedDay) {
        window.location.reload();
      } else {
        clearTimeout(timer);
        timer = setTimeout(tick, msUntilNext3am());
      }
    });
  }

  document.addEventListener("DOMContentLoaded", () => {
    const root = $(".agenda-page") || $(".agenda-calendar-page");
    if (!root) return;
    const addModal = $("#agenda-add-modal");
    if (addModal) initAddModal(addModal);
    initEdit(root);
    initAgendaFilter();
    if (root.classList.contains("agenda-calendar-page")) {
      initCalendarPage(root);
    } else {
      initChecks(root);
    }
    scheduleAutoDateAdvance(root);
    subscribeMonitor();
    processQueue();
  });
})();
