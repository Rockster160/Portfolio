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

  // Implicit submit-on-Enter is inconsistent across browsers (Chrome's native
  // time/date/color pickers swallow Enter; some select dropdowns do the same).
  // Make Enter always submit, unless the user is in a textarea (newline) or
  // focused on a button (let the button's own activation handle it).
  function bindEnterSubmit(form) {
    form.addEventListener("keydown", (e) => {
      if (e.key !== "Enter" || e.shiftKey || e.ctrlKey || e.metaKey || e.altKey) return;
      const t = e.target;
      if (t instanceof HTMLTextAreaElement) return;
      if (t instanceof HTMLButtonElement) return;
      e.preventDefault();
      form.requestSubmit();
    });
  }

  // All time values cross the wire as integer epoch seconds (UTC). The
  // browser is the only consumer that decides the display timezone, so
  // round-trip is exact: an event entered as "4pm" in the browser's local
  // zone always re-renders as "4pm" in that same browser. Anything that
  // takes an `epoch` arg below accepts either a number or a numeric
  // string (data-* attributes always arrive as strings).
  function fmtTime(epoch) {
    if (epoch === null || epoch === undefined || epoch === "") return "";
    const d = new Date(Number(epoch) * 1000);
    let h = d.getHours();
    const m = d.getMinutes();
    const ampm = h >= 12 ? "pm" : "am";
    h = h % 12;
    if (h === 0) h = 12;
    return `${h}:${String(m).padStart(2, "0")}${ampm}`;
  }

  // Browser-local "YYYY-MM-DDTHH:MM" string → integer epoch seconds.
  // This is the canonical write-path conversion: whatever wall-clock the
  // user typed gets anchored to their browser timezone before being sent
  // to the server. The server never re-interprets the wall-clock.
  function localInputToEpoch(localStr) {
    if (!localStr) return null;
    const ts = new Date(localStr).getTime();
    return Number.isFinite(ts) ? Math.floor(ts / 1000) : null;
  }

  // ---------- server-rendered time hydration ----------
  // Server emits `<span data-time-hydrate data-start-epoch=... data-format=...>`
  // empty; the browser fills in the localized string. Keeps all timezone
  // decisions on the device, never on the server.
  function fmtDay(epoch)  {
    const d = new Date(Number(epoch) * 1000);
    return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  }
  function fmtCalTime(epoch) {
    // Compact form used in the month-grid cells: "9a", "2:30p"
    const d = new Date(Number(epoch) * 1000);
    let h = d.getHours();
    const m = d.getMinutes();
    const suffix = h >= 12 ? "p" : "a";
    h = h % 12 || 12;
    return m === 0 ? `${h}${suffix}` : `${h}:${String(m).padStart(2, "0")}${suffix}`;
  }
  function hydrateOneTimeNode(node) {
    const start = node.getAttribute("data-start-epoch");
    const end   = node.getAttribute("data-end-epoch");
    const fmt   = node.getAttribute("data-format") || "time";
    if (!start) return;
    let text = "";
    switch (fmt) {
      case "day":
        text = fmtDay(start);
        break;
      case "range":
        text = end ? `${fmtTime(start)}–${fmtTime(end)}` : fmtTime(start);
        break;
      case "cal":
        text = fmtCalTime(start);
        break;
      default:
        text = fmtTime(start);
    }
    node.textContent = text;
  }
  function hydrateTimeNodes(root = document) {
    root.querySelectorAll("[data-time-hydrate]").forEach(hydrateOneTimeNode);
  }
  document.addEventListener("DOMContentLoaded", () => hydrateTimeNodes());
  // Watch for server-rendered fragments inserted after page load (Monitor
  // updates, modal opens, section replaces) so new items also hydrate.
  new MutationObserver((records) => {
    for (const r of records) {
      r.addedNodes.forEach((n) => {
        if (n.nodeType !== 1) return;
        if (n.hasAttribute && n.hasAttribute("data-time-hydrate")) hydrateOneTimeNode(n);
        if (n.querySelectorAll) hydrateTimeNodes(n);
      });
    }
  }).observe(document.body, { childList: true, subtree: true });

  // Promise-returning replacement for `window.confirm()`. Renders into the
  // shared #agenda-confirm-modal (rendered by `_confirm_modal.html.erb`
  // via the render_modal helper, so it uses the standard overlay +
  // animation infra from app/javascript/src/modals.js).
  //
  // Resolves to true on Confirm, false on any other dismissal — including
  // the modal's built-in outside-click + close-button paths. We listen
  // for the `modal.hidden` jQuery event (fired by hideModal) as the
  // canonical "user is done" signal, so we don't have to handle each
  // dismissal source ourselves.
  function agendaConfirm({ title, body, confirmLabel, danger }) {
    const modal = document.getElementById("agenda-confirm-modal");
    if (!modal || typeof window.showModal !== "function" || !window.jQuery) {
      return Promise.resolve(window.confirm(`${title}\n\n${body || ""}`));
    }
    const titleEl = modal.querySelector(".agenda-confirm-title");
    const bodyEl  = modal.querySelector(".agenda-confirm-body");
    const okBtn   = modal.querySelector(".agenda-confirm-ok");
    if (titleEl) titleEl.textContent = title || "Are you sure?";
    if (bodyEl) {
      bodyEl.textContent = body || "";
      bodyEl.classList.toggle("hidden", !body);
    }
    if (okBtn) {
      okBtn.textContent = confirmLabel || "Confirm";
      okBtn.classList.toggle("af-btn-danger", danger !== false);
      okBtn.classList.toggle("af-btn-primary", danger === false);
    }

    return new Promise((resolve) => {
      let confirmed = false;
      const $modal = window.jQuery(modal);
      const onOk     = () => { confirmed = true; window.hideModal("#agenda-confirm-modal"); };
      const onHidden = () => {
        okBtn?.removeEventListener("click", onOk);
        $modal.off("modal.hidden", onHidden);
        resolve(confirmed);
      };
      okBtn?.addEventListener("click", onOk);
      $modal.on("modal.hidden", onHidden);
      window.showModal("#agenda-confirm-modal");
    });
  }
  window.AgendaConfirm = agendaConfirm;

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
  // Persistent banner + queue of permanently-failed ops so the user
  // knows which changes were dropped server-side and can dismiss when
  // they've understood. Bumping the version key (DROPPED_KEY) drops
  // anything left from a stale session.
  const DROPPED_KEY = "agendaDroppedOps:v1";
  function getDropped() {
    try { return JSON.parse(localStorage.getItem(DROPPED_KEY) || "[]"); }
    catch (_) { return []; }
  }
  function saveDropped(list) {
    localStorage.setItem(DROPPED_KEY, JSON.stringify(list));
    updateDroppedBanner();
  }
  function recordDropped(op, status) {
    const list = getDropped();
    list.push({ url: op.url, method: op.method, status, at: new Date().toISOString() });
    saveDropped(list);
  }
  function updateDroppedBanner() {
    const banner = document.querySelector(".agenda-error-dropped");
    if (!banner) return;
    const list = getDropped();
    banner.classList.toggle("hidden", list.length === 0);
    const count = banner.querySelector(".agenda-error-dropped-count");
    if (count) count.textContent = list.length > 1 ? ` (${list.length})` : "";
  }

  // Drains one op at a time, removing the head only after `res.ok` so a
  // tab close or network drop mid-flight leaves the op queued for retry.
  // Five consecutive 5xx attempts surface the disconnect banner so the
  // user sees that something is wrong even though the WS may still be up.
  let _processing = false;
  let _consecutive5xx = 0;
  async function processQueue() {
    if (_processing) return; // single-flight
    _processing = true;
    try {
      while (true) {
        const q = getQueue();
        if (q.length === 0) {
          _consecutive5xx = 0;
          // Clear the banner if it was up only because of 5xx retries.
          clearApiErrorBanner();
          return;
        }
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
          showApiErrorBanner();
          return;
        }
        if (!res.ok) {
          if (res.status >= 400 && res.status < 500) {
            // 4xx is permanent. Drop the op so we don't loop, but record
            // it so the user gets a persistent indicator they can read
            // and dismiss — silent drops were leaving changes lost
            // without any explanation.
            const dropped = getQueue();
            if (dropped[0] && dropped[0].dedup_key === op.dedup_key) {
              dropped.shift();
              saveQueue(dropped);
            }
            recordDropped(op, res.status);
            console.error(`Dropped queued op (server ${res.status}):`, op);
            continue;
          }
          // 5xx — transient. Leave queued; surface a banner if it keeps
          // happening so the user sees that retries are stalling.
          _consecutive5xx += 1;
          if (_consecutive5xx >= 5) showApiErrorBanner();
          return;
        }
        _consecutive5xx = 0;
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

  // Reuses the existing .agenda-error "Disconnected" banner copy — the
  // user-facing message is the same either way ("changes aren't reaching
  // the server"). The Monitor connect handler also clears it.
  function showApiErrorBanner() { $(".agenda-error")?.classList.remove("hidden"); }
  function clearApiErrorBanner() {
    // Don't clear if Monitor is currently disconnected — that handler owns
    // the banner too.
    if (window.__agendaMonitorDisconnected) return;
    $(".agenda-error")?.classList.add("hidden");
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
    const startTs = Number(data.start_at) * 1000;
    if (!Number.isFinite(startTs)) return;
    const startDate = new Date(startTs);
    const pad = (n) => String(n).padStart(2, "0");
    const itemDate = `${startDate.getFullYear()}-${pad(startDate.getMonth() + 1)}-${pad(startDate.getDate())}`;
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

    const existing = Array.from(section.querySelectorAll(".agenda-item"));
    const next = existing.find((node) => {
      const t = Number(node.dataset.startAt) * 1000;
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
      const source = li.dataset.source;
      hidden.value = id;
      pick.style.setProperty("--picked-agenda-color", color);
      if (label) label.textContent = name;
      $$("li", menu).forEach((other) => {
        const sel = other === li;
        other.classList.toggle("selected", sel);
        if (sel) other.setAttribute("aria-selected", "true");
        else other.removeAttribute("aria-selected");
      });
      if (fireChange && typeof onChange === "function") onChange(id, color, name, source);
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
    const monthlyDaysWrap = $(".monthly-days-wrap", form);
    const monthlyNthWrap  = $(".monthly-nth-wrap", form);
    const monthlyPosSelect  = $(".add-monthly-set-pos", form);
    const monthlyWdaySelect = $(".add-monthly-set-wday", form);
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
      syncMonthlyMode();

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

    // Inside the Monthly frequency: switch between specific days-of-month
    // (chips) and the Nth weekday picker. Default the nth-pickers from the
    // current date so the user sees a sensible starting selection.
    function syncMonthlyMode() {
      if (!freqSelect) return;
      const mode = form.querySelector("input.add-monthly-mode-radio:checked")?.value || "day-of-month";
      const showNth = freqSelect.value === "monthly" && mode === "nth-weekday";
      monthlyDaysWrap?.classList.toggle("hidden", showNth);
      monthlyNthWrap?.classList.toggle("hidden", !showNth);
      if (!showNth || !dateInput) return;

      const ref = localDateFromInput(dateInput.value);
      if (monthlyPosSelect && !monthlyPosSelect.dataset.userSet)  monthlyPosSelect.value = ordinalPositionForDate(ref);
      if (monthlyWdaySelect && !monthlyWdaySelect.dataset.userSet) monthlyWdaySelect.value = WDAY_KEYS[ref.getDay()];
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
        // Either custom+month or monthly+nth — same payload shape.
        const isMonthly = data.freq === "monthly";
        if (isMonthly) {
          if (monthlyPosSelect) {
            monthlyPosSelect.value = String(data.by_set_pos);
            monthlyPosSelect.dataset.userSet = "1";
          }
          if (data.by_day?.[0] && monthlyWdaySelect) {
            monthlyWdaySelect.value = data.by_day[0];
            monthlyWdaySelect.dataset.userSet = "1";
          }
          form.querySelector("input.add-monthly-mode-radio[value='nth-weekday']")?.click();
        } else {
          if (setPosSelect) setPosSelect.value = String(data.by_set_pos);
          form.querySelector("input.add-month-mode-radio[value='nth-weekday']")?.click();
          if (data.by_day?.[0] && setWdaySelect) setWdaySelect.value = data.by_day[0];
        }
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
        const monthlyMode = form.querySelector("input.add-monthly-mode-radio:checked")?.value || "day-of-month";
        if (monthlyMode === "nth-weekday") {
          recurrence.by_set_pos = parseInt(monthlyPosSelect?.value, 10);
          recurrence.by_day = [monthlyWdaySelect?.value];
        } else {
          const days = Array.from(monthDaySet).map((s) => parseInt(s, 10)).filter((n) => !Number.isNaN(n));
          if (days.length) recurrence.by_month_day = days;
        }
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
    dateInput?.addEventListener("change", () => { syncMonthMode(); syncMonthlyMode(); });
    endModeSelect?.addEventListener("change", syncEndMode);
    $$("input.add-monthly-mode-radio", form).forEach((r) => r.addEventListener("change", syncMonthlyMode));
    monthlyPosSelect?.addEventListener("change", () => { monthlyPosSelect.dataset.userSet = "1"; });
    monthlyWdaySelect?.addEventListener("change", () => { monthlyWdaySelect.dataset.userSet = "1"; });

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
    // unless the user has manually changed it. Picking a Google agenda
    // also locks the kind to "event" — Google calendars only contain
    // events, not tasks/triggers.
    let colorTouched = false;
    const agendaPicker = bindAgendaPicker(form, (id, color, _name, source) => {
      if (!colorTouched && colorInput && color) {
        colorInput.value = color;
        paintColor(color);
      }
      if (source === "google" && activeKind !== "event") {
        activeKind = "event";
        syncKind();
      }
      $$(".kind-btn", form).forEach((b) => {
        const lock = source === "google" && b.dataset.kind !== "event";
        b.disabled = lock;
        b.classList.toggle("locked", lock);
        b.title = lock ? "Only events can be added to a Google calendar" : "";
      });
    });

    const alldayField    = $(".add-allday-field", form);
    const alldayInput    = $(".add-allday-input", form);
    const alldayEndField = $(".add-allday-end-field", form);
    const timeFields     = $(".add-time-fields", form);

    function syncKind() {
      $$(".kind-btn", form).forEach((b) => b.classList.toggle("active", b.dataset.kind === activeKind));
      endField.classList.toggle("hidden", activeKind !== "event");
      $(".add-trigger-field", form)?.classList.toggle("hidden", activeKind !== "trigger");
      // All-day only applies to events.
      alldayField?.classList.toggle("hidden", activeKind !== "event");
      if (activeKind !== "event" && alldayInput) alldayInput.checked = false;
      syncAllDay();
    }

    function syncAllDay() {
      const isAllDay = !!alldayInput?.checked;
      timeFields?.classList.toggle("hidden", isAllDay);
      alldayEndField?.classList.toggle("hidden", !isAllDay);
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
      endTouched = false;
      syncKind();
      sched.syncFreq();
    }

    $$(".kind-btn", form).forEach((btn) => {
      btn.addEventListener("click", () => { activeKind = btn.dataset.kind; syncKind(); });
    });
    alldayInput?.addEventListener("change", syncAllDay);

    // End time auto-tracks start (+1h) until the user edits end themselves.
    let endTouched = false;
    endInput?.addEventListener("input", () => { endTouched = true; });
    startInput?.addEventListener("input", () => {
      if (endTouched || !startInput.value || !endInput) return;
      const [h, m] = startInput.value.split(":").map(Number);
      if (!Number.isFinite(h) || !Number.isFinite(m)) return;
      const pad = (n) => String(n).padStart(2, "0");
      endInput.value = `${pad((h + 1) % 24)}:${pad(m)}`;
    });

    if (colorInput) {
      colorInput.addEventListener("input", () => {
        colorTouched = true;
        paintColor(colorInput.value);
      });
    }

    form.addEventListener("submit", (e) => { e.preventDefault(); submit(); });
    bindEnterSubmit(form);

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
      const isAllDay = activeKind === "event" && !!alldayInput?.checked;
      // All-day: start at 00:00 on `date`, end exclusive on next day (or
      // user-specified end-date+1). Matches the Google convention so the
      // overlap query + duration math agree across both write paths.
      const allDayEnd = $(".add-allday-end", form)?.value || date;
      const startAt = localInputToEpoch(isAllDay ? `${date}T00:00` : `${date}T${startTime}`);

      const endAt = (() => {
        if (activeKind !== "event") return null;
        if (!isAllDay) return localInputToEpoch(`${date}T${endTime}`);
        const next = new Date(`${allDayEnd}T00:00`);
        next.setDate(next.getDate() + 1);
        const pad = (n) => String(n).padStart(2, "0");
        return localInputToEpoch(`${next.getFullYear()}-${pad(next.getMonth() + 1)}-${pad(next.getDate())}T00:00`);
      })();
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
            all_day:            isAllDay,
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
  // The native checked flip is the click ack — the box stays in the user's
  // intended state. We mark the row pending and let the post-broadcast
  // HTML swap deliver the canonical truth. On any kind of failure we
  // KEEP the box in its new state (matches user intent), queue the op for
  // retry, and surface a pending indicator. Reverting the box on failure
  // would contradict what the user just clicked — the queue + persistent
  // error banner handle the rest.
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

      ajax(op.method, op.url, op.body)
        .catch(() => {
          // Queue + keep the box checked. The processor will keep
          // retrying on reconnect / next visibility tick; the persistent
          // error banner surfaces if it lands in the 4xx-dropped state.
          enqueue(op);
          toast("Saved offline — will sync");
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
    const alldayField    = $(".add-allday-field", form);
    const alldayInput    = $(".add-allday-input", form);
    const alldayEndField = $(".add-allday-end-field", form);
    const alldayEndInput = $(".add-allday-end", form);
    const timeFields     = $(".add-time-fields", form);

    let activeKind = "task";
    let currentRecurring = false;
    let currentScheduleData = null;

    function syncKind() {
      $$(".kind-btn", form).forEach((b) => b.classList.toggle("active", b.dataset.kind === activeKind));
      $(".add-end-field", form).classList.toggle("hidden", activeKind !== "event");
      $(".add-trigger-field", form)?.classList.toggle("hidden", activeKind !== "trigger");
      // All-day toggle only applies to events. Hide for non-events but
      // don't reset its value — the user may toggle kind back and we want
      // to preserve what they were composing.
      alldayField?.classList.toggle("hidden", activeKind !== "event");
      if (activeKind !== "event" && alldayInput) alldayInput.checked = false;
      syncAllDay();
    }

    function syncAllDay() {
      const isAllDay = !!alldayInput?.checked;
      timeFields?.classList.toggle("hidden", isAllDay);
      alldayEndField?.classList.toggle("hidden", !isAllDay);
    }

    alldayInput?.addEventListener("change", syncAllDay);

    $$(".kind-btn", form).forEach((btn) => {
      btn.addEventListener("click", () => { activeKind = btn.dataset.kind; syncKind(); });
    });

    // Mirror the add-modal behavior: picking a Google agenda forces kind
    // to event and disables Task / Trigger buttons (Google calendars only
    // hold events). On switch back to a local agenda we re-enable.
    const editAgendaPicker = bindAgendaPicker(form, (_id, _color, _name, source) => {
      const isGoogle = source === "google";
      if (isGoogle && activeKind !== "event") {
        activeKind = "event";
        syncKind();
      }
      $$(".kind-btn", form).forEach((b) => {
        const lock = isGoogle && b.dataset.kind !== "event";
        b.disabled = lock;
        b.classList.toggle("locked", lock);
        b.title = lock ? "Only events can be added to a Google calendar" : "";
      });
    });

    // Click model on each agenda-item row:
    //   .agenda-item-check-zone (label wrapping the checkbox) → native
    //     <label for> toggles the checkbox; we don't intercept.
    //   [data-open-details] (the body button)         → details modal
    //   [data-edit-item]   (the pencil)               → edit modal
    //   .preview rows open the details modal (read-only view) but never
    //     the edit modal — edits land on the wrong day if applied to a
    //     tomorrow stub. Checkbox stays disabled on previews via the
    //     server-rendered `disabled` attr.
    root.addEventListener("click", (e) => {
      const dataEl = e.target.closest("[data-item-id]");
      if (!dataEl) return;

      const isPreview = dataEl.classList.contains("preview");

      if (e.target.closest("[data-edit-item]")) {
        if (isPreview) return;
        e.preventDefault();
        e.stopPropagation();
        openModal(dataEl);
        return;
      }
      if (e.target.closest("[data-open-details]")) {
        e.preventDefault();
        e.stopPropagation();
        openDetailsModal(dataEl);
      }
    });

    // Edit button inside the details modal — closes details, opens the
    // edit modal for the same item. Only visible when row is editable
    // (openDetailsModal flips the hidden class based on data-readonly).
    const detailsModalEl = document.getElementById("agenda-item-details");
    detailsModalEl?.querySelector("[data-edit-from-details]")?.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const target = detailsModalItem;
      if (!target) return;
      if (window.hideModal) window.hideModal("#agenda-item-details");
      openModal(target);
    });

    function openModal(item) {
      const d = item.dataset;
      $(".add-item-id", form).value = d.itemId;
      $(".add-name", form).value = d.name;
      if (d.agendaId) editAgendaPicker?.setValue(d.agendaId);

      activeKind = d.kind || "task";

      // All-day state must be applied BEFORE syncKind so the hide/show
      // logic of time vs date-range fields lands correctly.
      const isAllDay = d.allDay === "true";
      if (alldayInput) alldayInput.checked = isAllDay;
      syncKind();

      // Item's start_at is integer epoch seconds; split into local date + time-of-day.
      const [startDate, startTime] = splitEpochToDateAndTime(d.startAt);
      const [, endTime] = splitEpochToDateAndTime(d.endAt);
      $(".add-date", form).value = startDate;
      $(".add-start", form).value = startTime || "09:00";
      $(".add-end", form).value = endTime || "10:00";
      // For all-day, populate the end-date field with the item's inclusive
      // end_date (server emits via data-end-date so we don't recompute the
      // exclusive→inclusive conversion in JS).
      if (alldayEndInput) {
        alldayEndInput.value = (isAllDay ? (d.endDate || startDate) : startDate);
      }

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

    function splitEpochToDateAndTime(epoch) {
      if (!epoch) return ["", ""];
      const local = epochToLocalInput(epoch);
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
      const isAllDay = activeKind === "event" && !!alldayInput?.checked;
      const allDayEnd = alldayEndInput?.value || date;
      const startAt = localInputToEpoch(isAllDay ? `${date}T00:00` : `${date}T${startTime}`);
      // For all-day we mirror Google's convention (exclusive end-date): a
      // one-day all-day from May 27 ends at May 28T00:00. Multi-day adds
      // one day to the picked end-date.
      const endAt = (() => {
        if (activeKind !== "event") return null;
        if (!isAllDay) return localInputToEpoch(`${date}T${endTime}`);
        const next = new Date(`${allDayEnd}T00:00`);
        next.setDate(next.getDate() + 1);
        const pad = (n) => String(n).padStart(2, "0");
        return localInputToEpoch(`${next.getFullYear()}-${pad(next.getMonth() + 1)}-${pad(next.getDate())}T00:00`);
      })();
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
          all_day:            isAllDay,
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
    bindEnterSubmit(form);

    restoreBtn?.addEventListener("click", async () => {
      const ok = await agendaConfirm({
        title:        "Restore to the recurring series?",
        body:         "This will discard the edits you've made to this one occurrence and use the series defaults instead.",
        confirmLabel: "Restore",
        danger:       true,
      });
      if (!ok) return;

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

    deleteBtn.addEventListener("click", async () => {
      const scope = currentScope();
      const isSeries = currentRecurring && scope === "series";
      const title = isSeries ? "Delete this and all future occurrences?"
        : (currentRecurring ? "Delete just this occurrence?" : "Delete this item?");
      const body = isSeries
        ? "All upcoming items in this series will be removed. History stays intact."
        : null;

      const ok = await agendaConfirm({
        title,
        body,
        confirmLabel: isSeries ? "Delete all" : "Delete",
        danger:       true,
      });
      if (!ok) return;

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

  // Integer epoch seconds → "YYYY-MM-DDTHH:MM" in the browser's local zone,
  // suitable for an <input type="datetime-local">. The inverse of
  // localInputToEpoch above.
  function epochToLocalInput(epoch) {
    if (epoch === null || epoch === undefined || epoch === "") return "";
    const d = new Date(Number(epoch) * 1000);
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
  // Filter state lives on the SERVER (AgendaPreference) so a toggle on
  // one device propagates to every other. The first paint uses a
  // localStorage cache (for instant render before the server fetch
  // returns) and we PATCH any change back, which fans out a Monitor
  // broadcast — see subscribeMonitor's `received` handler.
  const PREFS_CACHE_KEY = "agendaPreferencesCache:v1";
  const COMPLETED_GRACE_MS = 5000;

  function defaultPrefs() {
    return { hidden_agenda_ids: [], hide_completed: { task: false, event: false, trigger: false }, hide_tentative: false };
  }
  let currentPrefs = (() => {
    try {
      const cached = JSON.parse(localStorage.getItem(PREFS_CACHE_KEY) || "null");
      return cached && typeof cached === "object" ? Object.assign(defaultPrefs(), cached) : defaultPrefs();
    } catch (_) { return defaultPrefs(); }
  })();

  function persistPrefsCache() {
    localStorage.setItem(PREFS_CACHE_KEY, JSON.stringify(currentPrefs));
  }
  function applyPreferenceSnapshot(prefs) {
    if (!prefs || typeof prefs !== "object") return;
    currentPrefs = {
      hidden_agenda_ids: Array.isArray(prefs.hidden_agenda_ids) ? prefs.hidden_agenda_ids.map(String) : [],
      hide_completed:    Object.assign({ task: false, event: false, trigger: false }, prefs.hide_completed || {}),
      hide_tentative:    !!prefs.hide_tentative,
    };
    persistPrefsCache();
    syncFilterPanelToPrefs();
    applyAgendaVisibility();
  }
  function pushPrefsToServer() {
    persistPrefsCache();
    return ajax("PATCH", "/agenda_preference", {
      agenda_preference: {
        hidden_agenda_ids: currentPrefs.hidden_agenda_ids,
        hide_completed:    currentPrefs.hide_completed,
        hide_tentative:    currentPrefs.hide_tentative,
      },
    }).catch(() => {
      // Network drop — keep the local cache; reconnect will fetch authoritative.
    });
  }
  function fetchPrefsFromServer() {
    return fetch("/agenda_preference", {
      credentials: "same-origin",
      headers:     { "Accept": "application/json", "X-Requested-With": "XMLHttpRequest" },
    })
      .then((res) => (res.ok ? res.json() : null))
      .then((json) => { if (json) applyPreferenceSnapshot(json); })
      .catch(() => { /* fall back to cache */ });
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
    const hidden = new Set(currentPrefs.hidden_agenda_ids.map(String));
    const completedHidden = currentPrefs.hide_completed;
    const tentativeHidden = currentPrefs.hide_tentative;
    document.querySelectorAll("[data-agenda-id]").forEach((el) => {
      if (!el.classList.contains("agenda-item") && !el.classList.contains("cal-item")) return;
      const hideByAgenda = hidden.has(el.dataset.agendaId);
      const kind = el.dataset.kind;
      const isCrossedOut = el.classList.contains("crossed-out");
      const itemId = el.dataset.itemId;
      const inGrace = itemId && gracedItemIds.has(itemId);
      const hideByCompleted = isCrossedOut && !!completedHidden[kind] && !inGrace;
      const hideByTentative = tentativeHidden && el.classList.contains("tentative");
      el.classList.toggle("hidden-by-filter", hideByAgenda || hideByCompleted || hideByTentative);
    });
  }

  // Reflects the current prefs snapshot into the filter panel checkboxes.
  // Used both on initial hydrate and after a Monitor broadcast updates
  // prefs from another device.
  function syncFilterPanelToPrefs() {
    const panel = document.querySelector(".agenda-filter-panel");
    if (!panel) return;
    const hiddenSet = new Set(currentPrefs.hidden_agenda_ids.map(String));
    panel.querySelectorAll("input[type=checkbox][data-agenda-id]").forEach((cb) => {
      cb.checked = !hiddenSet.has(cb.dataset.agendaId);
    });
    panel.querySelectorAll("input[type=checkbox][data-completed-kind]").forEach((cb) => {
      cb.checked = !!currentPrefs.hide_completed[cb.dataset.completedKind];
    });
    const tentCb = panel.querySelector("input[type=checkbox][data-hide-tentative]");
    if (tentCb) tentCb.checked = currentPrefs.hide_tentative;
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
    const completedHidden = currentPrefs.hide_completed;
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

    // Initial paint from local cache while the server fetch is in flight.
    syncFilterPanelToPrefs();
    applyAgendaVisibility();
    fetchPrefsFromServer();

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
        const id = String(agendaCb.dataset.agendaId);
        const ids = new Set(currentPrefs.hidden_agenda_ids.map(String));
        if (agendaCb.checked) ids.delete(id); else ids.add(id);
        currentPrefs.hidden_agenda_ids = Array.from(ids);
        applyAgendaVisibility();
        pushPrefsToServer();
        return;
      }

      const completedCb = e.target.closest("input[type=checkbox][data-completed-kind]");
      if (completedCb) {
        // Direct filter toggles apply immediately — no grace window. Grace
        // is only for the transition caused by a completion event.
        currentPrefs.hide_completed = Object.assign({}, currentPrefs.hide_completed, {
          [completedCb.dataset.completedKind]: completedCb.checked,
        });
        applyAgendaVisibility();
        pushPrefsToServer();
        return;
      }

      const tentCb = e.target.closest("input[type=checkbox][data-hide-tentative]");
      if (tentCb) {
        currentPrefs.hide_tentative = tentCb.checked;
        applyAgendaVisibility();
        pushPrefsToServer();
      }
    });
  }

  // Details modal — read-only view shown on body click. When the user has
  // edit permission on the row, surfaces an Edit button that swaps to the
  // edit modal for the same item.
  let detailsModalItem = null;
  function openDetailsModal(dataEl) {
    const modal = document.getElementById("agenda-item-details");
    if (!modal) return;
    detailsModalItem = dataEl;
    const editBtn = modal.querySelector("[data-edit-from-details]");
    if (editBtn) {
      const canEdit = !dataEl.hasAttribute("data-readonly") && !dataEl.classList.contains("preview");
      editBtn.classList.toggle("hidden", !canEdit);
    }
    const d = dataEl.dataset;
    const set = (sel, val) => {
      const node = modal.querySelector(sel);
      if (node) node.textContent = val || "";
    };
    const dot = modal.querySelector("[data-agenda-color-target]");
    if (dot) dot.style.background = d.agendaColor || "";
    set("[data-agenda-name-target]", d.agendaName);
    set("[data-name-target]", d.name);

    const start = d.startAt ? new Date(Number(d.startAt) * 1000) : null;
    const end = d.endAt ? new Date(Number(d.endAt) * 1000) : null;
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
        window.__agendaMonitorDisconnected = false;
        $(".agenda-error")?.classList.add("hidden");
        // Two things on reconnect: drain anything that piled up offline AND
        // re-sync the view, since we likely missed broadcasts while down.
        processQueue();
        const r = $(".agenda-page") || $(".agenda-calendar-page");
        if (r) refreshView(r);
      },
      disconnected: function () {
        window.__agendaMonitorDisconnected = true;
        clearTimeout(disconnectTimer);
        disconnectTimer = setTimeout(() => {
          $(".agenda-error")?.classList.remove("hidden");
        }, DISCONNECT_GRACE_MS);
      },
      received: function (data) {
        // Filter prefs broadcast — apply locally without a server refetch.
        if (data && data.preferences) {
          applyPreferenceSnapshot(data.preferences);
          return;
        }
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
        applyAgendaVisibility();
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
      // setHours(3, 0, 0, 0) on a spring-forward day lands on 04:00 (03:00
      // doesn't exist), making us fire an hour late. Clamp to a minute
      // past 03:00 if the result overshoots — we still want a 3am-ish
      // rollover and the small drift is acceptable.
      const now = new Date();
      const next = new Date(now);
      next.setHours(3, 0, 0, 0);
      if (next.getHours() === 4) next.setHours(3, 1, 0, 0); // DST skip — clamp
      if (next <= now) {
        next.setDate(next.getDate() + 1);
        next.setHours(3, 0, 0, 0);
        if (next.getHours() === 4) next.setHours(3, 1, 0, 0);
      }
      return Math.max(next - now, 60_000);
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
    // Wire the dismiss button on the permanent-failure banner.
    document.querySelector(".agenda-error-dropped .agenda-error-dismiss")?.addEventListener("click", () => {
      saveDropped([]);
    });
    updateDroppedBanner();
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

    // Deep link: ?item=<display_id> auto-opens the details modal for that
    // row once the page has rendered. Used by the Jarvis "schedule" reply
    // link so the user lands directly on the new event.
    const itemParam = new URLSearchParams(window.location.search).get("item");
    if (itemParam) {
      const row = root.querySelector(`[data-item-id="${CSS.escape(itemParam)}"]`);
      if (row) openDetailsModal(row);
    }
  });
})();
