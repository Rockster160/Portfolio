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

  // Mirrors the ERB strftime("%-l:%M%P") so JS- and server-rendered items
  // show the same string after a Monitor refresh.
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
  function saveQueue(q) {
    localStorage.setItem(QUEUE_KEY, JSON.stringify(q));
    updatePendingBadge();
  }
  function enqueue(op) {
    const q = getQueue();
    const idx = q.findIndex((p) => p.dedup_key === op.dedup_key);
    if (idx >= 0) q[idx] = op;
    else q.push(op);
    saveQueue(q);
  }

  function updatePendingBadge() {
    const badge = document.querySelector(".agenda-pending-badge");
    if (!badge) return;
    let count = 0;
    try { count = (JSON.parse(localStorage.getItem(QUEUE_KEY) || "[]")).length; }
    catch (_) { count = 0; }
    const numEl = badge.querySelector(".agenda-pending-badge-count");
    if (numEl) numEl.textContent = count > 0 ? ` ${count}` : "";
    badge.classList.toggle("hidden", count === 0);
  }
  // Drains one op at a time, removing the head only after `res.ok` so a
  // tab close or network drop mid-flight leaves the op queued for retry.
  let _processing = false;
  async function processQueue() {
    if (_processing) return; // single-flight
    _processing = true;
    try {
      while (true) {
        const q = getQueue();
        if (q.length === 0) return;
        const op = q[0];
        let res;
        try {
          res = await fetch(op.url, {
            method:      op.method,
            credentials: "same-origin",
            headers: {
              "Content-Type":     "application/json",
              "Accept":           "application/json",
              "X-CSRF-Token":     csrfToken(),
              "X-Requested-With": "XMLHttpRequest",
            },
            body: op.body ? JSON.stringify(op.body) : undefined,
          });
        } catch (_e) {
          // Network drop — leave op queued, retry on next online / WS connect.
          return;
        }
        if (!res.ok) {
          if (res.status >= 400 && res.status < 500) {
            // 4xx is permanent — dropping prevents infinite loop. Log loudly.
            const dropped = getQueue();
            if (dropped[0] && dropped[0].dedup_key === op.dedup_key) {
              dropped.shift();
              saveQueue(dropped);
            }
            console.error(`Dropped queued op (server ${res.status}):`, op);
            continue;
          }
          // 5xx — transient. Leave it for retry, stop draining now.
          return;
        }
        // Server ack'd. Pop the head off persistent storage. Re-read first
        // in case another op was enqueued concurrently.
        const after = getQueue();
        if (after[0] && after[0].dedup_key === op.dedup_key) {
          after.shift();
          saveQueue(after);
        }
      }
    } finally {
      _processing = false;
    }
  }
  window.addEventListener("online", processQueue);

  // Lightweight optimistic placeholder for a just-submitted add. Server
  // re-renders the real row on the post-broadcast HTML refresh. This is
  // intentionally minimal — no item id, no kind classes, no edit affordance —
  // because anything more would duplicate _item.html.erb and drift.
  function insertPendingPlaceholder(data) {
    const root = $(".agenda-page");
    if (!root) return; // calendar view has no day sections
    const currentDate = root.dataset.currentDate;
    if (!currentDate) return;
    const itemDate = (data.start_at || "").split("T")[0];
    if (!itemDate) return;
    const offset = Math.round(
      (new Date(itemDate + "T12:00:00") - new Date(currentDate + "T12:00:00")) / 86400000,
    );
    if (offset < 0) return;
    const section = $(`[data-section="day-${offset}"]`);
    if (!section) return;
    section.querySelector(".agenda-empty")?.remove();

    const color = data.color || data.agenda_color || "#0160FF";
    const placeholder = el(`
      <div class="agenda-item is-pending"
           style="--item-color: ${color}; --agenda-color: ${data.agenda_color || color};"
           data-start-at="${data.start_at}">
        <div class="agenda-item-body">
          <span class="agenda-item-time">${fmtTime(data.start_at)}</span>
          <span class="agenda-item-text">
            <span class="agenda-item-name">${escapeHtml(data.name || "")}</span>
          </span>
        </div>
      </div>
    `);

    const startTs = new Date(data.start_at).getTime();
    const existing = Array.from(section.querySelectorAll(".agenda-item"));
    const next = existing.find((node) => {
      const t = new Date(node.dataset.startAt).getTime();
      return Number.isFinite(t) && t > startTs;
    });
    if (next) section.insertBefore(placeholder, next);
    else section.appendChild(placeholder);
  }

  // ---------- shared agenda picker ----------
  // Custom dropdown — Safari ignores backgrounds inside native <option>s,
  // so each option lives in a floating list with a colored dot + tinted
  // row. A hidden input under the hood preserves the `.add-agenda-id`
  // value the rest of the form code reads.
  //
  // Returns { value(), setValue(id), close() }. `onChange` fires as
  // (id, color, name) when the user picks an option.
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
      // Defer outside-click until the opening click finishes bubbling.
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
  // Recurrence/days/until/count UI shared between the add and edit modals.
  // Returns helpers for prefill, payload build, and clear.
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

    // Prefills from AgendaSchedule#serialize_for_edit. Skips writing
    // starts_on into the date input — that input is the OCCURRENCE date
    // (edit modal) or the new item's date (add modal); overwriting it
    // collapses future-phantom edits onto the schedule's start date.
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

    // Build agenda_schedule payload from form state. `startsOn` preserves
    // the schedule's original start date during edit-series flows so the
    // rule edit doesn't shift starts_on onto the occurrence's date.
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

    let activeKind = "event";
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

    // Switching agendas defaults the item color to the agenda's color
    // unless the user has manually changed it.
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
      activeKind = "event";
      sched.resetChips();
      dateInput.value = form.dataset.defaultDate;
      // Re-sync the picker's label/dot to the hidden input's reset value.
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

    // Default start time: next-top-of-the-hour if the date is today,
    // otherwise 09:00.
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

      const agendaMeta = (() => { // for the optimistic placeholder
        const sel = $(".add-agenda-id", form);
        if (!sel) return {};
        // Hidden input — look at the corresponding <li> in the menu for color/name.
        const li = form.querySelector(`.agenda-pick-menu li[data-id="${agendaId}"]`);
        return { color: li?.dataset.color, name: li?.dataset.name };
      })();

      if (freq === "never") {
        const itemBody = {
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
        };

        // Optimistic placeholder so the user sees the item immediately. WS
        // broadcast → refreshView → section replace will swap it out for the
        // real row. If the request fails, the placeholder stays visible
        // (pending) and the op is queued for replay on reconnect.
        insertPendingPlaceholder({
          name,
          kind:               activeKind,
          color,
          start_at:           startAt,
          end_at:             endAt,
          location,
          notes,
          agenda_id:          agendaId,
          agenda_color:       agendaMeta.color,
          agenda_name:        agendaMeta.name,
        });

        closeModal();

        ajax("POST", form.dataset.itemUrl, itemBody)
          .then(() => toast("Added"))
          .catch(() => {
            enqueue({
              dedup_key: `create:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`,
              url:       form.dataset.itemUrl,
              method:    "POST",
              body:      itemBody,
            });
            toast("Saved offline — will sync when reconnected");
          });
        return;
      }

      const schedulePayload = sched.buildSchedulePayload({
        name, kind: activeKind, color,
        startTime, endTime, date, triggerExpression,
      });
      schedulePayload.agenda_id = agendaId;
      schedulePayload.location = location;
      schedulePayload.notes = notes;
      const scheduleBody = { agenda_schedule: schedulePayload };
      closeModal();
      ajax("POST", form.dataset.scheduleUrl, scheduleBody)
        .then(() => toast("Added"))
        .catch(() => {
          enqueue({
            dedup_key: `create-schedule:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`,
            url:       form.dataset.scheduleUrl,
            method:    "POST",
            body:      scheduleBody,
          });
          toast("Saved offline — will sync when reconnected");
        });
    }

    syncKind();
  }

  // ---------- checkbox toggle (with offline queue) ----------
  // Strictly pending-until-confirmed: the native checked flip is the click
  // ack (so the user sees their tap register), but we mark the row pending,
  // disable the input, and let the post-broadcast HTML swap deliver the
  // canonical truth. On failure we revert the native flip and re-enable.
  function initChecks(root) {
    root.addEventListener("change", (e) => {
      const cb = e.target.closest(".agenda-item-check");
      if (!cb) return;
      const url = cb.dataset.checkedUrl;
      const row = cb.closest(".agenda-item");
      const intent = cb.checked;
      const op = {
        dedup_key: `check:${url}`,
        url,
        method:    "PATCH",
        body:      { agenda_item: { completed_at: intent ? "now" : "" } },
      };

      row?.classList.add("is-pending");
      cb.disabled = true;

      ajax(op.method, op.url, op.body)
        .catch(() => {
          // Couldn't reach the server — revert the checkbox so the visual
          // matches the database, queue for retry, and clear pending.
          cb.checked = !intent;
          row?.classList.remove("is-pending");
          cb.disabled = false;
          enqueue(op);
          toast("Saved offline — will sync", "error");
        });
      // No .then(): on success we wait for the broadcast → HTML swap to
      // replace this row with the server-rendered truth, which carries
      // .crossed-out (or not) authoritatively and drops .is-pending.
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
    const restoreBtn = $(".add-restore", form);

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

    const editAgendaPicker = bindAgendaPicker(form);

    // Editable rows: pencil carries data-edit-item → edit modal. The
    // <label> body just toggles the checkbox natively. Readonly rows
    // carry data-edit-item + data-readonly → details modal instead.
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
      const isDetached = d.detached === "true";
      $(".add-scope-field", form).classList.toggle("hidden", !currentRecurring);

      // Series radio + restore button toggle on detachment: an unaltered
      // recurring item defaults to "this and all future" (the common case
      // — rename/move a daily standup, propagate to the series). An
      // already-detached one is a one-off and stays a one-off; instead of
      // a series radio, surface a "Restore to cycle" button that puts it
      // back into the recurrence.
      const seriesRadio  = form.querySelector("input[name='scope'][value='series']");
      const occRadio     = form.querySelector("input[name='scope'][value='occurrence']");
      const seriesLabel  = seriesRadio?.closest("label");
      if (currentRecurring && isDetached) {
        if (occRadio) occRadio.checked = true;
        if (seriesLabel) seriesLabel.classList.add("hidden");
        if (restoreBtn) restoreBtn.classList.remove("hidden");
      } else {
        if (seriesRadio) seriesRadio.checked = true;
        if (seriesLabel) seriesLabel.classList.remove("hidden");
        if (restoreBtn) restoreBtn.classList.add("hidden");
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

      // Series edits send the full schedule payload so recurrence/days/
      // until/count are all editable. location + notes get merged in
      // separately — buildSchedulePayload doesn't include them.
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

      // Mark pending and close immediately; .is-pending stays on if the
      // request fails because the op gets queued for retry.
      const itemEl = findItemEl($(".add-item-id", form).value);
      itemEl?.classList.add("is-pending");
      closeModal();

      ajax("PATCH", form.dataset.itemUrl, payload)
        .then(() => toast("Saved"))
        .catch(() => {
          enqueue({
            // Latest edit to a given item wins — dedup by URL.
            dedup_key: `update:${form.dataset.itemUrl}`,
            url:       form.dataset.itemUrl,
            method:    "PATCH",
            body:      payload,
          });
          toast("Saved offline — will sync when reconnected");
        });
    });

    restoreBtn?.addEventListener("click", () => {
      const msg = "Restore this occurrence back to the recurring series?\n\n" +
                  "All changes you've made to this event — date, time, name, " +
                  "notes, location, color, etc. — will be lost.";
      if (!window.confirm(msg)) return;

      const itemEl = findItemEl($(".add-item-id", form).value);
      itemEl?.classList.add("is-pending-delete");
      const url = `${form.dataset.itemUrl}/restore`;
      closeModal();

      ajax("POST", url)
        .then(() => toast("Restored to cycle"))
        .catch(() => {
          enqueue({
            dedup_key: `restore:${form.dataset.itemUrl}`,
            url,
            method: "POST",
          });
          toast("Saved offline — will sync when reconnected");
        });
    });

    deleteBtn.addEventListener("click", () => {
      const scope = currentScope();
      const label = deleteBtn.textContent;
      if (!window.confirm(`${label} — are you sure?`)) return;

      const itemEl = findItemEl($(".add-item-id", form).value);
      itemEl?.classList.add("is-pending-delete");
      const deleteUrl = `${form.dataset.itemUrl}?scope=${scope}`;
      closeModal();

      ajax("DELETE", deleteUrl)
        .then(() => toast("Deleted"))
        .catch(() => {
          enqueue({
            dedup_key: `delete:${form.dataset.itemUrl}`,
            url:       deleteUrl,
            method:    "DELETE",
          });
          toast("Saved offline — will sync when reconnected");
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

  // ---------- agenda visibility filter ----------
  // Per-device localStorage filter — applies to both `.agenda-item` and
  // `.cal-item` rows (they share `data-agenda-id`).
  const AGENDA_HIDDEN_KEY = "agendaHidden:v1";
  // Per-kind "hide completed" toggles: { task: bool, event: bool, trigger: bool }
  const COMPLETED_HIDDEN_KEY = "agendaCompletedHidden:v1";
  // When a previously-visible row becomes crossed-out and would now be
  // hidden by the completed filter, we keep it visible for this many ms so
  // the user gets a beat to see the strikethrough. Subsequent completions
  // within the window reset the timer so a flurry of checks gets removed
  // together, not staggered.
  const COMPLETED_GRACE_MS = 5000;

  function getHiddenAgendas() {
    try {
      const raw = JSON.parse(localStorage.getItem(AGENDA_HIDDEN_KEY) || "[]");
      return Array.isArray(raw) ? raw.map(String) : [];
    } catch (_) { return []; }
  }
  function saveHiddenAgendas(ids) {
    localStorage.setItem(AGENDA_HIDDEN_KEY, JSON.stringify(ids));
  }

  function getCompletedHidden() {
    const empty = { task: false, event: false, trigger: false };
    try {
      const raw = JSON.parse(localStorage.getItem(COMPLETED_HIDDEN_KEY) || "{}");
      return {
        task:    !!raw.task,
        event:   !!raw.event,
        trigger: !!raw.trigger,
      };
    } catch (_) { return empty; }
  }
  function saveCompletedHidden(state) {
    localStorage.setItem(COMPLETED_HIDDEN_KEY, JSON.stringify(state));
  }

  // Items currently in their post-completion grace window. Stays visible
  // even when the completed filter says hide. Cleared together when the
  // shared timer fires.
  const gracedItemIds = new Set();
  let graceTimer = null;
  function scheduleGraceFlush() {
    clearTimeout(graceTimer);
    graceTimer = setTimeout(() => {
      gracedItemIds.clear();
      graceTimer = null;
      applyAgendaVisibility();
    }, COMPLETED_GRACE_MS);
  }

  function applyAgendaVisibility() {
    const hidden = new Set(getHiddenAgendas());
    const completedHidden = getCompletedHidden();
    document.querySelectorAll("[data-agenda-id]").forEach((el) => {
      if (!el.classList.contains("agenda-item") && !el.classList.contains("cal-item")) return;
      const hideByAgenda = hidden.has(el.dataset.agendaId);
      const kind = el.dataset.kind;
      const isCrossedOut = el.classList.contains("crossed-out");
      const itemId = el.dataset.itemId;
      const inGrace = itemId && gracedItemIds.has(itemId);
      const hideByCompleted = isCrossedOut && !!completedHidden[kind] && !inGrace;
      el.classList.toggle("hidden-by-filter", hideByAgenda || hideByCompleted);
    });
  }

  // Pre-swap snapshot of crossed-out state by item id. Used after a DOM
  // swap to detect newly-completed rows that would now be hidden by the
  // completed filter — those get a grace window instead of disappearing
  // instantly.
  function snapshotItemState(root) {
    const snap = new Map();
    const sel = ".agenda-item[data-item-id], .cal-item[data-item-id]";
    (root || document).querySelectorAll(sel).forEach((el) => {
      snap.set(el.dataset.itemId, {
        crossedOut: el.classList.contains("crossed-out"),
      });
    });
    return snap;
  }

  // After a swap, find rows that flipped to crossed-out AND would be hidden
  // by the user's completed-kind filter. Add them to the grace set and
  // (re)arm the shared timer.
  function graceNewlyCompleted(prevSnap, root) {
    const completedHidden = getCompletedHidden();
    if (!completedHidden.task && !completedHidden.event && !completedHidden.trigger) return;
    let added = false;
    const sel = ".agenda-item[data-item-id], .cal-item[data-item-id]";
    (root || document).querySelectorAll(sel).forEach((el) => {
      if (!el.classList.contains("crossed-out")) return;
      if (!completedHidden[el.dataset.kind]) return;
      const prev = prevSnap.get(el.dataset.itemId);
      // No prev entry → row didn't exist before (e.g. just got created
      // already completed). Treat as "already hidden" — no grace.
      if (!prev || prev.crossedOut) return;
      gracedItemIds.add(el.dataset.itemId);
      added = true;
    });
    if (added) scheduleGraceFlush();
  }

  function initAgendaFilter() {
    const btn = document.querySelector(".agenda-filter-btn");
    const panel = document.querySelector(".agenda-filter-panel");
    if (!btn || !panel) return;

    const hidden = new Set(getHiddenAgendas());
    panel.querySelectorAll("input[type=checkbox][data-agenda-id]").forEach((cb) => {
      cb.checked = !hidden.has(cb.dataset.agendaId);
    });
    const completedHidden = getCompletedHidden();
    panel.querySelectorAll("input[type=checkbox][data-completed-kind]").forEach((cb) => {
      cb.checked = !!completedHidden[cb.dataset.completedKind];
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
      const agendaCb = e.target.closest("input[type=checkbox][data-agenda-id]");
      if (agendaCb) {
        const id = agendaCb.dataset.agendaId;
        let next = getHiddenAgendas();
        if (agendaCb.checked) {
          next = next.filter((x) => x !== id);
        } else if (!next.includes(id)) {
          next.push(id);
        }
        saveHiddenAgendas(next);
        applyAgendaVisibility();
        return;
      }

      const completedCb = e.target.closest("input[type=checkbox][data-completed-kind]");
      if (completedCb) {
        // Direct filter toggles apply immediately — no grace window. Grace
        // is only for the transition caused by a completion event.
        const state = getCompletedHidden();
        state[completedCb.dataset.completedKind] = completedCb.checked;
        saveCompletedHidden(state);
        applyAgendaVisibility();
      }
    });
  }

  // Read-only details modal for viewer-permission rows.
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
    // Monitor.subscribe() fires `disconnected` synchronously on subscribe;
    // 500ms grace prevents the page-load handshake from flashing the banner.
    const DISCONNECT_GRACE_MS = 500;
    let disconnectTimer = null;

    window.Monitor.subscribe("agenda", {
      connected: function () {
        clearTimeout(disconnectTimer);
        disconnectTimer = null;
        $(".agenda-error")?.classList.add("hidden");
        // Two things on reconnect: drain anything that piled up offline AND
        // re-sync the view, since we likely missed broadcasts while down.
        processQueue();
        const r = $(".agenda-page") || $(".agenda-calendar-page");
        if (r) refreshView(r);
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

  // Best-effort re-sync of the current view. Fetches the per-view JSON
  // (or HTML for calendar) and swaps sections in place. Always fails
  // silent — a dropped network leaves the page as it is rather than
  // navigating into a broken state.
  function refreshView(root) {
    const date = root.dataset.currentDate;
    if (root.classList.contains("agenda-calendar-page")) {
      refreshCalendarGrid(root);
      return;
    }
    if (!date) return;
    const basePath = root.classList.contains("agenda-week-page") ? "/agenda/week" : "/agenda";
    const url = `${basePath}?date=${encodeURIComponent(date)}`;
    fetch(url, {
      credentials: "same-origin",
      headers:     { "Accept": "text/html", "X-Requested-With": "XMLHttpRequest" },
    })
      .then((res) => (res.ok ? res.text() : null))
      .then((html) => { if (html) swapDaySections(root, html); })
      .catch((err) => console.error("agenda refresh failed (will retry on next signal)", err));
  }

  // Server renders the canonical HTML; we extract the sections we care
  // about and swap them in place. Single source of truth — no JS
  // template literal mirroring _item.html.erb.
  function swapDaySections(root, html) {
    const doc = new DOMParser().parseFromString(html, "text/html");
    const freshRoot = doc.querySelector(".agenda-page");
    if (!freshRoot) return;

    const prevSnap = snapshotItemState(root);

    const freshCarry = freshRoot.querySelector(".section-carry");
    const currentCarry = root.querySelector(".section-carry");
    if (freshCarry && currentCarry) {
      currentCarry.replaceWith(freshCarry);
    } else if (freshCarry) {
      const firstDay = root.querySelector(".agenda-section[data-section-day]");
      if (firstDay) firstDay.before(freshCarry);
    } else if (currentCarry) {
      currentCarry.remove();
    }

    freshRoot.querySelectorAll(".agenda-section[data-section-day]").forEach((freshSection) => {
      const key = freshSection.dataset.sectionDay;
      const current = root.querySelector(`.agenda-section[data-section-day="${key}"]`);
      if (current) current.replaceWith(freshSection);
    });

    graceNewlyCompleted(prevSnap, root);
    applyAgendaVisibility();
  }

  // Calendar refresh: fetch the current page's HTML, swap the date-bar
  // and .cal-grid. Avoids a per-cell JSON apply and survives a month-
  // crossing rollover (server-rendered HTML brings the new month's
  // label + prev/next links along with the grid).
  function refreshCalendarGrid(root) {
    fetch(window.location.href, {
      credentials: "same-origin",
      headers:     { "Accept": "text/html", "X-Requested-With": "XMLHttpRequest" },
    })
      .then((res) => (res.ok ? res.text() : null))
      .then((html) => {
        if (!html) return;
        const doc = new DOMParser().parseFromString(html, "text/html");
        const freshRoot = doc.querySelector(".agenda-calendar-page");
        if (!freshRoot) return;

        // Keep root.dataset.currentDate aligned with the displayed month —
        // applyDateRoll uses this to detect cross-month rolls.
        if (freshRoot.dataset.currentDate) {
          root.dataset.currentDate = freshRoot.dataset.currentDate;
        }

        const prevSnap = snapshotItemState(root);

        const swap = (sel) => {
          const fresh = freshRoot.querySelector(sel);
          const current = root.querySelector(sel);
          if (fresh && current) current.replaceWith(fresh);
        };
        // Date bar carries the "June 2026" label + prev/next links — must
        // update alongside the grid for cross-month rolls.
        swap(".agenda-date-bar");
        swap(".cal-grid");

        graceNewlyCompleted(prevSnap, root);
        applyAgendaVisibility(); // re-apply the localStorage filter
      })
      .catch((err) => console.error("calendar refresh failed", err));
  }

  // All three views (day/week/calendar) shown on the plain /agenda URLs (no
  // `?date=` override) roll to the new "today" automatically at 3am local.
  // 3am is a more humane day boundary than midnight.
  //
  // The rollover NEVER hard-reloads — it updates DOM in place and triggers
  // a graceful JSON re-sync. If the network is dead overnight (laptop
  // closed, wifi flaky, server hiccup), the page stays exactly as it was;
  // we never strand the user on a broken reload-mid-network-drop screen.
  function scheduleAutoDateAdvance(root) {
    try {
      const url = new URL(window.location.href);
      if (url.searchParams.has("date")) return; // pinned date — leave alone
    } catch (_) { return; }

    // "Day key" treats hours 0:00–2:59 as still belonging to the previous
    // calendar day, so the perceived day only ticks over at 3am.
    function dayKey(d = new Date()) {
      const x = new Date(d);
      if (x.getHours() < 3) x.setDate(x.getDate() - 1);
      const pad = (n) => String(n).padStart(2, "0");
      return `${x.getFullYear()}-${pad(x.getMonth() + 1)}-${pad(x.getDate())}`;
    }
    function msUntilNext3am() {
      const now = new Date();
      const next = new Date(now);
      next.setHours(3, 0, 0, 0);
      if (next <= now) next.setDate(next.getDate() + 1);
      return next - now;
    }

    let loadedDay = dayKey();
    let timer = null;
    function tick() {
      const today = dayKey();
      if (today !== loadedDay) {
        applyDateRoll(root, today);
        loadedDay = today;
      }
      timer = setTimeout(tick, msUntilNext3am());
    }
    timer = setTimeout(tick, msUntilNext3am());

    // Returns whether the perceived day changed so the caller can skip
    // its own refreshView (applyDateRoll has already fired one).
    return function checkRolloverNow() {
      const today = dayKey();
      const rolled = today !== loadedDay;
      if (rolled) {
        applyDateRoll(root, today);
        loadedDay = today;
      }
      clearTimeout(timer);
      timer = setTimeout(tick, msUntilNext3am());
      return rolled;
    };
  }

  function applyDateRoll(root, newDateIso) {
    root.dataset.currentDate = newDateIso;
    const newDate = new Date(newDateIso + "T12:00:00"); // noon → avoids DST edge

    // Matches the ERB's strftime("%a, %b %-d, %Y").
    const label = root.querySelector(".date-label");
    if (label) {
      label.textContent = newDate.toLocaleDateString(undefined, {
        weekday: "short", month: "short", day: "numeric", year: "numeric",
      });
    }

    const basePath = root.classList.contains("agenda-week-page") ? "/agenda/week"
                   : root.classList.contains("agenda-calendar-page") ? "/agenda/calendar"
                   : "/agenda";
    const prevIso = isoOffset(newDateIso, -1);
    const nextIso = isoOffset(newDateIso, +1);
    const prevLink = root.querySelector(".date-nav.prev");
    const nextLink = root.querySelector(".date-nav.next");
    if (prevLink) prevLink.setAttribute("href", `${basePath}?date=${prevIso}`);
    if (nextLink) nextLink.setAttribute("href", `${basePath}?date=${nextIso}`);

    // Within-month rollover only moves the .is-today highlight; crossing
    // a month boundary re-fetches the grid. Pinned ?month=YYYY-MM stays
    // put either way.
    if (root.classList.contains("agenda-calendar-page")) {
      const displayedMonth = (root.dataset.currentDate || "").slice(0, 7);
      const newMonth = newDateIso.slice(0, 7);
      const monthPinned = (() => {
        try { return new URL(window.location.href).searchParams.has("month"); }
        catch (_) { return false; }
      })();
      if (newMonth !== displayedMonth && !monthPinned) {
        // Server now returns the new month (perceived_today.beginning_of_month).
        // refreshCalendarGrid swaps both the grid + the date-bar in place —
        // no reload, URL bar unchanged.
        refreshCalendarGrid(root);
      } else {
        const old = root.querySelector(".cal-day.is-today");
        if (old) old.classList.remove("is-today");
        const fresh = root.querySelector(`.cal-day[data-date="${newDateIso}"]`);
        if (fresh) fresh.classList.add("is-today");
      }
      return;
    }

    refreshView(root);
  }

  function isoOffset(iso, days) {
    const d = new Date(iso + "T12:00:00");
    d.setDate(d.getDate() + days);
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
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
    updatePendingBadge();
    const checkRollover = scheduleAutoDateAdvance(root);

    // Foreground re-sync — mobile browsers suspend the ActionCable socket
    // while backgrounded and may miss broadcasts.
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState !== "visible") return;
      // Skip the explicit refreshView when checkRollover already did one.
      const rolled = checkRollover && checkRollover();
      if (!rolled) refreshView(root);
      processQueue();
    });

    subscribeMonitor();
    processQueue();
  });
})();
