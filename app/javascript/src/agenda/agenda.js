(function () {
  // Cross-modal handoff: initAddModal exposes a prefill+show entry point so
  // the follow-up flow can fill the add modal with a source event's
  // attributes + a new date. initFollowUpModal exposes `.open(source)` so
  // the edit modal's "Follow up" button can launch the day picker.
  let addModalPrefillAndShow = null;
  let followUpAPI = null;

  // ---------- helpers ----------
  function $(sel, root = document) { return root.querySelector(sel); }
  function $$(sel, root = document) { return Array.from(root.querySelectorAll(sel)); }

  // 3am-aware "today". Hours 0:00–2:59 belong to the previous calendar
  // day so the perceived day matches User#perceived_today on the server.
  // Exposed on window so list_view.js and agenda_cal.js can share one
  // implementation instead of reimplementing the pad-and-shift dance.
  window.__agendaLogicalToday = function (dayStart = 3) {
    const d = new Date();
    if (d.getHours() < dayStart) d.setDate(d.getDate() - 1);
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  };

  function el(html) {
    const t = document.createElement("template");
    t.innerHTML = html.trim();
    return t.content.firstElementChild;
  }

  function csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || "";
  }

  // Implicit submit-on-Enter is inconsistent across browsers (Chrome's native
  // time/date/color pickers swallow Enter; some select dropdowns do the same).
  // Make Enter always submit, unless the user is in a textarea (newline) or
  // focused on a button (let the button's own activation handle it).
  // Cmd/Ctrl+Enter ALWAYS submits — including from inside a textarea —
  // so Notes (the only textarea in these modals) gets the universal
  // "send" shortcut from Slack/Discord/Gmail without losing newline
  // typing via plain Enter.
  function bindEnterSubmit(form) {
    form.addEventListener("keydown", (e) => {
      if (e.key !== "Enter") return;
      const t = e.target;
      if (t instanceof HTMLButtonElement) return;
      if (e.metaKey || e.ctrlKey) {
        e.preventDefault();
        form.requestSubmit();
        return;
      }
      if (e.shiftKey || e.altKey) return;
      if (t instanceof HTMLTextAreaElement) return;
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

  // YYYY-MM-DD → YYYY-MM-DD shifted by `days` (positive or negative),
  // anchored at local noon so DST transitions can't bump us across a day.
  function shiftIsoDate(iso, days) {
    if (!iso) return iso;
    const d = new Date(`${iso}T12:00:00`);
    d.setDate(d.getDate() + days);
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  }

  // Whole-day delta between two YYYY-MM-DD strings (anchored at local
  // noon to dodge DST). Returns non-negative — used to preserve a
  // start↔end day-span as the user moves the start date.
  function isoDateDelta(fromIso, toIso) {
    if (!fromIso || !toIso) return 0;
    const dayMs = 24 * 60 * 60 * 1000;
    const a = new Date(`${fromIso}T12:00:00`);
    const b = new Date(`${toIso}T12:00:00`);
    return Math.max(0, Math.round((b - a) / dayMs));
  }

  // Epoch seconds → YYYY-MM-DD in the browser's local timezone. Used to
  // hydrate the end-date input from data-end-date (server emits the
  // inclusive last-day midnight as epoch seconds).
  function epochToIsoDate(epoch) {
    if (epoch === null || epoch === undefined || epoch === "") return null;
    const n = Number(epoch);
    if (!Number.isFinite(n)) return null;
    const d = new Date(n * 1000);
    const pad = (k) => String(k).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
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
    const prefix = node.getAttribute("data-prefix") || "";
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
    node.textContent = `${prefix}${text}`;
  }
  function hydrateTimeNodes(root = document) {
    root.querySelectorAll("[data-time-hydrate]").forEach(hydrateOneTimeNode);
  }
  // In-place renderers (agenda_item_renderer.js, month_view.js, etc.) patch
  // an existing time node's data-* attributes without removing/replacing the
  // node. The MutationObserver below only fires on added-nodes, so without
  // this surface, a changed format/epoch is silently ignored and the visible
  // text stays stale — e.g. flipping an event to all-day patched every data
  // attr correctly but the time label kept showing the old "9:00–10:00" range.
  window.__hydrateAgendaTimeNode = hydrateOneTimeNode;
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

  // Three-way prompt for a drag-and-drop edit on a recurring event.
  // Resolves to "occurrence" | "future" | null (null = cancel / dismiss).
  // Uses the shared #agenda-recurring-scope-modal partial; same modal
  // infra (showModal + jQuery modal.hidden) as agendaConfirm.
  function agendaRecurringScope({ title, from, to, patternFrom, patternTo }) {
    const modal = document.getElementById("agenda-recurring-scope-modal");
    if (!modal || typeof window.showModal !== "function" || !window.jQuery) {
      // No modal available — degrade to default-occurrence (safest: only
      // moves this one event, matches pre-modal behavior).
      return Promise.resolve("occurrence");
    }
    const titleEl    = modal.querySelector(".agenda-recurring-scope-title");
    const occBtn     = modal.querySelector(".agenda-recurring-scope-occurrence");
    const futBtn     = modal.querySelector(".agenda-recurring-scope-future");
    const diffEl     = modal.querySelector("[data-recurring-scope-diff]");
    const fromEl     = modal.querySelector("[data-recurring-scope-from]");
    const toEl       = modal.querySelector("[data-recurring-scope-to]");
    const pLabelEl   = modal.querySelector("[data-recurring-scope-pattern-label]");
    const pRowEl     = modal.querySelector("[data-recurring-scope-pattern-row]");
    const pFromEl    = modal.querySelector("[data-recurring-scope-pattern-from]");
    const pToEl      = modal.querySelector("[data-recurring-scope-pattern-to]");
    if (titleEl) titleEl.textContent = title || "Edit recurring event";
    if (diffEl) {
      const hasOcc = !!(from && to);
      const hasPattern = !!(patternFrom && patternTo);
      diffEl.classList.toggle("hidden", !hasOcc && !hasPattern);
      if (fromEl) fromEl.textContent = from || "";
      if (toEl)   toEl.textContent   = to   || "";
      pLabelEl?.classList.toggle("hidden", !hasPattern);
      pRowEl?.classList.toggle("hidden", !hasPattern);
      if (pFromEl) pFromEl.textContent = patternFrom || "";
      if (pToEl)   pToEl.textContent   = patternTo   || "";
    }

    return new Promise((resolve) => {
      let choice = null;
      const $modal   = window.jQuery(modal);
      const onOcc    = () => { choice = "occurrence"; window.hideModal("#agenda-recurring-scope-modal"); };
      const onFut    = () => { choice = "future";     window.hideModal("#agenda-recurring-scope-modal"); };
      const onHidden = () => {
        occBtn?.removeEventListener("click", onOcc);
        futBtn?.removeEventListener("click", onFut);
        $modal.off("modal.hidden", onHidden);
        resolve(choice);
      };
      occBtn?.addEventListener("click", onOcc);
      futBtn?.addEventListener("click", onFut);
      $modal.on("modal.hidden", onHidden);
      window.showModal("#agenda-recurring-scope-modal");
    });
  }
  window.AgendaRecurringScope = agendaRecurringScope;

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
    // Stamp every mutation with the wall-clock instant of the user's
    // action — same contract the offline queue uses. The server resolves
    // conflicts by comparing this against the item's current updated_at,
    // so an online edit fired against a row another device just touched
    // 200ms earlier still sees its real edit moment, not the request's
    // arrival time.
    const headers = {
      "Content-Type":     "application/json",
      "Accept":           "application/json",
      "X-CSRF-Token":     csrfToken(),
      "X-Requested-With": "XMLHttpRequest",
    };
    if (method !== "GET") headers["X-Client-Mutation-At"] = String(Date.now());
    return fetch(url, {
      method,
      credentials: "same-origin",
      headers,
      body: body ? JSON.stringify(body) : undefined,
    }).then((res) => {
      if (!res.ok) throw new Error(`${method} ${url} → ${res.status}`);
      return res;
    });
  }

  // ---------- pending badge + dropped banner ----------
  // The write-first mutation queue (`AgendaMutationQueue` in
  // `src/agenda_store/mutation_queue.js`) owns everything queue-shaped:
  // persistence, FIFO drain, retry / backoff, cross-tab dedup, the
  // synthetic 503 fallback wired through the service worker. This file
  // owns only the user-visible reflection: the spinner badge in the
  // header and the dismissable "didn't save" banner.
  function updatePendingBadge() {
    const badge = document.querySelector(".agenda-pending-badge");
    if (!badge || !window.AgendaMutationQueue) return;
    const count = window.AgendaMutationQueue.loadQueue().length;
    const numEl = badge.querySelector(".agenda-pending-badge-count");
    if (numEl) numEl.textContent = count > 0 ? ` ${count}` : "";
    badge.classList.toggle("hidden", count === 0);
  }

  function updateDroppedBanner() {
    const banner = document.querySelector(".agenda-error-dropped");
    if (!banner || !window.AgendaMutationQueue) return;
    const list = window.AgendaMutationQueue.loadDropped();
    banner.classList.toggle("hidden", list.length === 0);
    const count = banner.querySelector(".agenda-error-dropped-count");
    if (count) count.textContent = list.length > 1 ? ` (${list.length})` : "";
  }

  // Subscribe registration runs inside DOMContentLoaded (below) — at
  // IIFE top-level `window.AgendaMutationQueue` isn't defined yet
  // because the esbuild-rails glob plugin invokes `src/agenda/agenda.js`
  // before `src/agenda_store/mutation_queue.js` (alphabetical). The
  // queue still drains; what got lost without this fix was the badge
  // updating on enqueue/dequeue.

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
    function buildSchedulePayload({ name, kind, color, startTime, endTime, date, endDate, triggerExpression, startsOn, allDay }) {
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

      // All-day schedules anchor at 00:00 with a 1-day-per-banner duration.
      // For a single-day all-day event allDayEnd === date → 24h (1440min).
      // For a multi-day all-day span (Mac-style drag across cells) we walk
      // the inclusive day count + multiply by 1440. Without this, all-day
      // schedules used to carry whatever the hidden time inputs had (e.g.
      // 19:00 + 60min) — materialize_upcoming! then built every occurrence
      // at 7pm for 1 hour, producing internally-inconsistent "all-day from
      // 7pm to 8pm" rows that displayed (and re-edited) as 1-hour events.
      let effectiveStartTime = startTime;
      let duration = null;
      if (kind === "event") {
        if (allDay) {
          effectiveStartTime = "00:00";
          const endIso = endDate || date;
          const dayMs = 24 * 60 * 60 * 1000;
          const startDt = new Date(`${date}T00:00`);
          const endDt = new Date(`${endIso}T00:00`);
          const days = Math.max(1, Math.round((endDt - startDt) / dayMs) + 1);
          duration = days * 24 * 60;
        } else if (endDate && endDate !== date) {
          // Multi-day timed: duration spans the wall-clock delta between
          // the start and end datetimes. minutesBetween() collapses to
          // time-of-day only, which would silently truncate to <24h.
          const startDt = new Date(`${date}T${startTime}`);
          const endDt = new Date(`${endDate}T${endTime}`);
          duration = Math.max(15, Math.round((endDt - startDt) / 60000));
        } else {
          duration = Math.max(15, minutesBetween(startTime, endTime));
        }
      }
      const endMode = endModeSelect ? endModeSelect.value : "never";
      const untilOn = endMode === "until" && untilInput?.value ? untilInput.value : null;
      const occurrenceCount = endMode === "count" && countInput?.value
        ? Math.max(1, parseInt(countInput.value, 10))
        : null;

      return {
        name,
        kind,
        color,
        start_time:         effectiveStartTime,
        duration_minutes:   duration,
        starts_on:          startsOn || date,
        until_on:           untilOn,
        occurrence_count:   occurrenceCount,
        trigger_expression: triggerExpression,
        all_day:            !!allDay,
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
    function applyAgendaChange(id, color, _name, source) {
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
    }
    const agendaPicker = bindAgendaPicker(form, applyAgendaChange);

    const alldayField    = $(".add-allday-field", form);
    const alldayInput    = $(".add-allday-input", form);
    const endRow         = $(".add-end-row", form);
    const endDateInput   = $(".add-end-date", form);
    const startTimeInput = $(".add-start-time", form);
    const endTimeInput   = $(".add-end-time", form);

    function syncKind() {
      $$(".kind-btn", form).forEach((b) => b.classList.toggle("active", b.dataset.kind === activeKind));
      // End row (date + time) only meaningful for events.
      endRow?.classList.toggle("hidden", activeKind !== "event");
      $(".add-trigger-field", form)?.classList.toggle("hidden", activeKind !== "trigger");
      // All-day only applies to events.
      alldayField?.classList.toggle("hidden", activeKind !== "event");
      if (activeKind !== "event" && alldayInput) alldayInput.checked = false;
      syncAllDay();
    }

    function syncAllDay() {
      const isAllDay = !!alldayInput?.checked;
      // Hide the time inputs but keep the date inputs visible — multi-day
      // all-day events still need both start + end date pickers.
      startTimeInput?.classList.toggle("hidden", isAllDay);
      endTimeInput?.classList.toggle("hidden", isAllDay);
    }

    // The `.agenda-page` shell stamps `data-current-date` as the day
    // the user is looking at (list_view rewrites it on client-side
    // nav). Reading it live means the advanced add form defaults to
    // that day instead of the day the page was originally
    // server-rendered for. Cal views need special handling: cal_month's
    // `data-current-date` is a month anchor (YYYY-MM-01), and cal_week's
    // is a within-week date that is stale if the tab was open across
    // 3am — in both cases fall back to fresh "today" rather than the
    // stale server stamp.
    function selectedDefaultDate() {
      const root = document.querySelector(".agenda-page");
      const freshToday = window.__agendaLogicalToday?.() || form.dataset.defaultDate;
      if (!root) return form.dataset.defaultDate;
      if (root.classList.contains("agenda-cal-month-page")) return freshToday;
      if (root.classList.contains("agenda-cal-week-page")) {
        const params = new URLSearchParams(window.location.search);
        if (!params.has("date")) return freshToday;
      }
      const iso = root.dataset?.currentDate || "";
      if (/^\d{4}-\d{2}-\d{2}$/.test(iso)) return iso;
      return freshToday;
    }

    function resetForm() {
      form.reset();
      activeKind = "event";
      sched.resetChips();
      const defaultDate = selectedDefaultDate();
      form.dataset.defaultDate = defaultDate;
      dateInput.value = defaultDate;
      if (endDateInput) endDateInput.value = defaultDate;
      priorStartDate = dateInput.value;
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

    // End date auto-tracks start date, preserving the day-delta the user
    // already configured (so a multi-day span shifts as a unit when start
    // moves). `priorStartDate` snapshots the value before the change so
    // we can measure the delta against the prior end-date.
    let priorStartDate = dateInput?.value || "";
    dateInput?.addEventListener("change", () => {
      const prev = priorStartDate;
      const next = dateInput.value;
      if (endDateInput && prev && next && prev !== next) {
        const delta = isoDateDelta(prev, endDateInput.value || prev);
        endDateInput.value = shiftIsoDate(next, delta);
      }
      priorStartDate = next;
    });

    if (colorInput) {
      colorInput.addEventListener("input", () => {
        colorTouched = true;
        paintColor(colorInput.value);
      });
    }

    form.addEventListener("submit", (e) => { e.preventDefault(); submit(); });
    bindEnterSubmit(form);

    // Suppresses the default start-time reset when the modal is being
    // opened with a prefill (follow-up flow). Consumed once per open.
    let suppressDefaultTime = false;

    if (window.jQuery) {
      window.jQuery(modal).on("modal.shown", () => {
        if (!suppressDefaultTime) {
          // Sync to the currently-viewed date so an add opened via the
          // header "+" after nav lands on the visible day, not the day
          // the shell was originally server-rendered for. Skipped when a
          // prefill already assigned specific values (follow-up flow +
          // quick-add advanced hand-off).
          const defaultDate = selectedDefaultDate();
          form.dataset.defaultDate = defaultDate;
          dateInput.value = defaultDate;
          if (endDateInput) endDateInput.value = defaultDate;
          priorStartDate = defaultDate;
          applyDefaultStartTime();
        }
        suppressDefaultTime = false;
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
      // End date is the user's picked inclusive last day (for all-day) or
      // the wall-clock end day (for timed multi-day). Defaults to start
      // date for single-day events.
      const endDate = endDateInput?.value || date;
      const startAt = localInputToEpoch(isAllDay ? `${date}T00:00` : `${date}T${startTime}`);

      const endAt = (() => {
        if (activeKind !== "event") return null;
        if (!isAllDay) {
          const e = localInputToEpoch(`${endDate}T${endTime}`);
          // Same-day fallback: end-time earlier than start-time on the
          // same day wraps to next day (preserves the pre-multi-day
          // behavior for a single-line timed event).
          if (endDate === date && e <= startAt) return e + 24 * 60 * 60;
          return e;
        }
        // All-day: mirror Google's exclusive end-date — bump one day past
        // the picked inclusive end.
        return localInputToEpoch(`${shiftIsoDate(endDate, 1)}T00:00`);
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
      // The form prefills arrive-early to a sensible default for events
      // that actually have a location to travel to, but a location-less
      // task/event has no "travel" to be early for — gate the field's
      // value behind a present location so phantom 5-minute pre-travel
      // bands don't show up on every location-less item.
      const arriveEarlyMinutes = location
        ? (parseInt($(".add-arrive-early", form)?.value, 10) || 0)
        : 0;
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
            arrive_early_minutes: arriveEarlyMinutes,
            notes,
            trigger_expression: triggerExpression,
          },
        };

        // Write-FIRST: build the canonical optimistic item, patch the
        // store (renderers pick it up on the next subscriber tick), and
        // queue the POST. Once the server confirms, upsertItem matches
        // by client_mutation_id and swaps the temp:* id for the real
        // one in-place — no flicker, no duplicate, no DOM identity
        // change.
        const mid    = window.AgendaMutationQueue.newMutationId();
        const tempId = window.AgendaMutationQueue.newTempId();
        const optimistic = window.AgendaOptimisticItem.buildOptimisticItem({
          id:                  tempId,
          client_mutation_id:  mid,
          name,
          kind:                activeKind,
          color,
          start_at:            Number(startAt),
          end_at:              endAt == null ? null : Number(endAt),
          all_day:             !!isAllDay,
          location,
          notes,
          arrive_early_minutes: arriveEarlyMinutes,
          agenda_id:           agendaId,
          agenda_name:         agendaMeta.name,
          agenda_color:        agendaMeta.color,
          agenda_source:       agendaMeta.source || "",
        });
        window.AgendaStore.upsertItem(optimistic);

        itemBody.agenda_item.client_mutation_id = mid;
        window.AgendaMutationQueue.enqueue({
          client_mutation_id: mid,
          kind:               "create",
          url:                form.dataset.itemUrl,
          method:             "POST",
          body:               itemBody,
          target_id:          tempId,
        });
        window.AgendaMutationQueue.flush();
        // Same shell-aware hook the quick-add modal uses — bring the
        // user to the date their event landed on.
        try { window.__agendaJumpToDate?.(Number(startAt)); } catch (_e) {}
        closeModal();
        return;
      }

      // Schedules don't have an in-store optimistic representation yet
      // (recurrence expansion is server-driven), so we don't patch the
      // store — but we DO go through the mutation queue so an offline
      // schedule-create is persisted and replayed on next reconnect.
      const schedulePayload = sched.buildSchedulePayload({
        name, kind: activeKind, color,
        startTime, endTime, date, endDate, triggerExpression,
        allDay: isAllDay,
      });
      schedulePayload.agenda_id = agendaId;
      schedulePayload.location = location;
      schedulePayload.arrive_early_minutes = arriveEarlyMinutes;
      schedulePayload.notes = notes;
      const scheduleMid = window.AgendaMutationQueue.newMutationId();
      schedulePayload.client_mutation_id = scheduleMid;
      const scheduleBody = { agenda_schedule: schedulePayload };
      window.AgendaMutationQueue.enqueue({
        client_mutation_id: scheduleMid,
        kind:               "create-schedule",
        url:                form.dataset.scheduleUrl,
        method:             "POST",
        body:               scheduleBody,
      });
      window.AgendaMutationQueue.flush();
      try { window.__agendaJumpToDate?.(Number(startAt)); } catch (_e) {}
      closeModal();
    }

    // Prefill+open path used by the follow-up flow. Source data carries the
    // original event's copyable attributes plus the user-picked target date;
    // we drop into the same form the user would have filled in by hand.
    function prefillAndShow(d) {
      // Color first so colorTouched=true; that way setValue's agenda swap
      // can't repaint over the source event's color.
      if (colorInput && d.color) {
        colorInput.value = d.color;
        paintColor(d.color);
        colorTouched = true;
      }
      if (d.agendaId) {
        agendaPicker?.setValue(d.agendaId);
        const li = form.querySelector(`.agenda-pick-menu li[data-id="${CSS.escape(String(d.agendaId))}"]`);
        if (li) applyAgendaChange(li.dataset.id, li.dataset.color, li.dataset.name, li.dataset.source);
      }
      if (nameInput) nameInput.value = d.name || "";
      activeKind = d.kind || "event";
      const isAllDay = !!d.allDay;
      if (alldayInput) alldayInput.checked = isAllDay;
      syncKind();

      if (dateInput && d.date) dateInput.value = d.date;
      // `endDate` is the canonical key; fall back to legacy `alldayEnd`
      // for callers that haven't migrated yet (quick_add follow-up etc).
      const prefillEndDate = d.endDate || d.alldayEnd || d.date || dateInput?.value || "";
      if (endDateInput) endDateInput.value = prefillEndDate;
      priorStartDate = dateInput?.value || "";
      if (startInput) startInput.value = d.startTime || "09:00";
      if (endInput) endInput.value = d.endTime || "10:00";
      // Mark end as user-touched so input on start doesn't auto-bump it.
      endTouched = true;

      $(".add-location", form).value = d.location || "";
      $(".add-notes", form).value = d.notes || "";
      const triggerExprInput = $(".add-trigger-expression", form);
      if (triggerExprInput) triggerExprInput.value = d.triggerExpression || "";

      // Follow-ups are always one-off. Reset the recurrence UI.
      const freqSelect = $(".add-freq", form);
      if (freqSelect) freqSelect.value = "never";
      sched.resetChips();
      sched.syncFreq();

      suppressDefaultTime = true;
      if (window.showModal) window.showModal("#agenda-add-modal");
    }
    addModalPrefillAndShow = prefillAndShow;
    // Expose globally so quick_add.js can hand off to the advanced form
    // when the user taps "Advanced" with a partially-parsed input.
    window.__agendaAddModalPrefill = prefillAndShow;

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
      const itemId = row?.dataset.itemId;
      const intent = cb.checked;

      row?.classList.add("is-pending");

      // Write-FIRST: optimistic store patch + persistent queue BEFORE
      // any network. User can dismiss the tab the instant they click
      // and the change replays on next launch. The renderer reads
      // `completed_at` to drive the checkbox state, so re-renders
      // (broadcasts, store changes) won't revert the user's click
      // until the server actually disagrees.
      if (!itemId) return;
      const mid = window.AgendaMutationQueue.newMutationId();
      window.AgendaStore.patchItem({
        id:           itemId,
        completed_at: intent ? Math.floor(Date.now() / 1000) : null,
      });
      window.AgendaMutationQueue.enqueue({
        client_mutation_id: mid,
        kind:               intent ? "complete" : "uncomplete",
        url,
        method:             "PATCH",
        body:               {
          agenda_item: {
            completed_at:       intent ? "now" : "",
            client_mutation_id: mid,
          },
        },
        dedup_key: `check:${url}`,
        target_id: itemId,
      });
      window.AgendaMutationQueue.flush();
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
    const endRow         = $(".add-end-row", form);
    const endDateInput   = $(".add-end-date", form);
    const startTimeInput = $(".add-start-time", form);
    const endTimeInput   = $(".add-end-time", form);
    const dateInput      = $(".add-date", form);

    let activeKind = "task";
    let currentRecurring = false;
    let currentScheduleData = null;
    let priorStartDate = "";

    function syncKind() {
      $$(".kind-btn", form).forEach((b) => b.classList.toggle("active", b.dataset.kind === activeKind));
      endRow?.classList.toggle("hidden", activeKind !== "event");
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
      // Hide just the time inputs — date inputs stay visible so a
      // multi-day all-day event can still pick its end date.
      startTimeInput?.classList.toggle("hidden", isAllDay);
      endTimeInput?.classList.toggle("hidden", isAllDay);
    }

    alldayInput?.addEventListener("change", syncAllDay);

    // End date auto-tracks start date with delta-preservation (matches
    // the add-modal behavior — a span configured by the user shifts as
    // a unit when start moves).
    dateInput?.addEventListener("change", () => {
      const prev = priorStartDate;
      const next = dateInput.value;
      if (endDateInput && prev && next && prev !== next) {
        const delta = isoDateDelta(prev, endDateInput.value || prev);
        endDateInput.value = shiftIsoDate(next, delta);
      }
      priorStartDate = next;
    });

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
    //   Checkbox stays disabled on previews via the server-rendered
    //   `disabled` attr; edits on preview rows resolve to the underlying
    //   item just like the details-modal Edit button does.
    root.addEventListener("click", (e) => {
      const dataEl = e.target.closest("[data-item-id]");
      if (!dataEl) return;

      if (e.target.closest("[data-edit-item]")) {
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

    // Hide / unhide. Recurring rows toggle their schedule_id (the whole
    // series); one-off rows toggle their item_id (just this row).
    detailsModalEl?.querySelector("[data-toggle-hide-recurring]")?.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const target = detailsModalItem;
      const t = detailsHideTarget(target);
      if (!t) return;
      const listKey = t.kind === "schedule" ? "hidden_schedule_ids" : "hidden_item_ids";
      const namesKey = t.kind === "schedule" ? "hidden_schedule_names" : "hidden_item_names";
      const set = new Set((currentPrefs[listKey] || []).map(String));
      if (set.has(t.key)) {
        set.delete(t.key);
      } else {
        set.add(t.key);
        // Remember the display name so the filter panel can list this
        // entry even after the row is hidden from the current view.
        currentPrefs[namesKey] = Object.assign(
          {},
          currentPrefs[namesKey] || {},
          { [t.key]: target.dataset.name || "" },
        );
      }
      currentPrefs[listKey] = Array.from(set);
      syncDetailsHideRecurring(target);
      syncFilterPanelToPrefs();
      applyAgendaVisibility();
      pushPrefsToServer();
    });

    function openModal(item) {
      const d = item.dataset;
      $(".add-item-id", form).value = d.itemId;
      $(".add-name", form).value = d.name;
      if (d.agendaId) editAgendaPicker?.setValue(d.agendaId);

      // Mirror the details modal: surface item-id + agenda-id as a
      // hover tooltip on the agenda-picker dot so users can read off
      // both IDs without poking at the DOM. Visible color of the dot
      // is set by the picker; the title attribute is debug-only.
      const pickDot = form.querySelector(".agenda-pick-toggle .agenda-pick-dot");
      if (pickDot) {
        pickDot.title = `Item: ${d.itemId || "—"}\nAgenda: ${d.agendaId || "—"}`;
      }

      activeKind = d.kind || "task";

      // All-day state must be applied BEFORE syncKind so the hide/show
      // logic of time vs date-range fields lands correctly.
      const isAllDay = d.allDay === "true";
      if (alldayInput) alldayInput.checked = isAllDay;
      syncKind();

      // Item's start_at is integer epoch seconds; split into local date + time-of-day.
      const [startDate, startTime] = splitEpochToDateAndTime(d.startAt);
      const [endDateFromEnd, endTime] = splitEpochToDateAndTime(d.endAt);
      $(".add-date", form).value = startDate;
      $(".add-start", form).value = startTime || "09:00";
      $(".add-end", form).value = endTime || "10:00";
      // End-date input is unified for all-day and timed multi-day events.
      // - All-day: prefer the server's inclusive end-date epoch (mirrors
      //   the exclusive→inclusive convention without recomputing in JS).
      // - Timed: use the actual end_at's local date so a multi-day timed
      //   event round-trips correctly.
      if (endDateInput) {
        const allDayEnd = epochToIsoDate(d.endDate) || startDate;
        endDateInput.value = isAllDay ? allDayEnd : (endDateFromEnd || startDate);
      }
      priorStartDate = startDate;

      $(".add-location", form).value = d.location || "";
      $(".add-arrive-early", form).value = parseInt(d.arriveEarlyMinutes, 10) || 0;
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

      // Series radio + restore button toggle on detachment.
      //
      // What the user sees IS what gets submitted: `currentScope()` reads
      // whichever radio is :checked, so the visual state is the source of
      // truth. Two cases:
      //   * Detached occurrence — it's a one-off; the series option has
      //     no series to apply to. We hide the series label AND uncheck
      //     it AND force the occurrence radio so the form can never
      //     silently submit `scope=series` for a row with no series.
      //   * Non-detached recurring — default to "this and all future"
      //     (the common case). HTML already has `checked` on the series
      //     radio, but re-affirm here so a prior detached-open doesn't
      //     leak state forward.
      // Restore button only appears for detached rows.
      const seriesRadio  = form.querySelector("input[name='scope'][value='series']");
      const occRadio     = form.querySelector("input[name='scope'][value='occurrence']");
      const seriesLabel  = seriesRadio?.closest("label");
      if (currentRecurring && isDetached) {
        if (seriesRadio) seriesRadio.checked = false;
        if (occRadio) occRadio.checked = true;
        if (seriesLabel) seriesLabel.classList.add("hidden");
        if (restoreBtn) restoreBtn.classList.remove("hidden");
      } else {
        if (occRadio) occRadio.checked = false;
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

    // Follow up: snapshot the form's current values (so unsaved edits in
    // the edit modal carry through), hand them to the follow-up day picker.
    $(".add-followup", form)?.addEventListener("click", (e) => {
      e.preventDefault();
      if (!followUpAPI) return;
      const dateVal = $(".add-date", form).value;
      const isAllDay = !!alldayInput?.checked;
      const src = {
        agendaId:          editAgendaPicker?.value(),
        name:              $(".add-name", form).value,
        kind:              activeKind,
        color:             $(".add-color", form).value,
        allDay:            isAllDay,
        date:              dateVal,
        endDate:           endDateInput?.value || dateVal,
        startTime:         $(".add-start", form).value,
        endTime:           $(".add-end", form).value,
        location:          $(".add-location", form).value,
        notes:             $(".add-notes", form).value,
        triggerExpression: $(".add-trigger-expression", form)?.value || "",
        month:             (dateVal || "").slice(0, 7),
      };
      if (window.hideModal) window.hideModal("#agenda-item-edit");
      followUpAPI.open(src);
    });

    form.addEventListener("submit", (e) => {
      e.preventDefault();
      const scope = currentScope();
      const date = $(".add-date", form).value;
      const startTime = $(".add-start", form).value || "09:00";
      const endTime = $(".add-end", form).value || "10:00";
      const isAllDay = activeKind === "event" && !!alldayInput?.checked;
      const endDate = endDateInput?.value || date;
      const startAt = localInputToEpoch(isAllDay ? `${date}T00:00` : `${date}T${startTime}`);
      // Timed: use the user-picked end date + time directly. Same-day
      // wraps to next day if end<=start to preserve legacy behavior.
      // All-day: mirror Google's exclusive end-date (bump one day past
      // the inclusive end the user picked).
      const endAt = (() => {
        if (activeKind !== "event") return null;
        if (!isAllDay) {
          const e = localInputToEpoch(`${endDate}T${endTime}`);
          if (endDate === date && e <= startAt) return e + 24 * 60 * 60;
          return e;
        }
        return localInputToEpoch(`${shiftIsoDate(endDate, 1)}T00:00`);
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
          arrive_early_minutes: parseInt($(".add-arrive-early", form)?.value, 10) || 0,
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
          startTime, endTime, date, endDate, triggerExpression,
          startsOn: currentScheduleData?.starts_on,
          allDay: isAllDay,
        });
        payload.agenda_schedule.location = payload.agenda_item.location;
        payload.agenda_schedule.arrive_early_minutes = payload.agenda_item.arrive_early_minutes;
        payload.agenda_schedule.notes = payload.agenda_item.notes;
      }

      // Mark pending and close immediately; .is-pending stays on if the
      // request fails because the op gets queued for retry.
      const itemIdRaw = $(".add-item-id", form).value;
      const itemEl = findItemEl(itemIdRaw);
      itemEl?.classList.add("is-pending");
      closeModal();

      if (!itemIdRaw) return;
      // Write-FIRST: optimistic patch + persistent queue, no network in
      // the hot path. The store's stale-time guard prevents a slow
      // broadcast from reverting the user's edit until the server
      // catches up (with a fresher updated_at).
      const mid = window.AgendaMutationQueue.newMutationId();
      const patch = {
        id:            String(itemIdRaw),
        name:          payload.agenda_item.name,
        location:      payload.agenda_item.location,
        notes:         payload.agenda_item.notes,
        start_at:      payload.agenda_item.start_at,
        end_at:        payload.agenda_item.end_at,
        all_day:       payload.agenda_item.all_day,
        color:         payload.agenda_item.color,
        arrive_early_minutes: payload.agenda_item.arrive_early_minutes,
        client_mutation_id: mid,
        updated_at:    Math.floor(Date.now() / 1000),
      };
      // Reflect into presentation_attrs too so the in-place patcher
      // sees the fresh values on the next render.
      const existing = window.AgendaStore.getItem(String(itemIdRaw));
      if (existing) {
        const pa = Object.assign({}, existing.presentation_attrs || {}, {
          "name":     patch.name || "",
          "location": patch.location || "",
          "notes":    patch.notes || "",
          "color":    patch.color || "",
          "start-at": patch.start_at || 0,
          "end-at":   patch.end_at == null ? null : patch.end_at,
          "all-day":  !!patch.all_day,
          "arrive-early-minutes": patch.arrive_early_minutes || 0,
        });
        patch.presentation_attrs = pa;
      }
      window.AgendaStore.patchItem(patch);

      payload.agenda_item.client_mutation_id = mid;
      window.AgendaMutationQueue.enqueue({
        client_mutation_id: mid,
        kind:               "update",
        url:                form.dataset.itemUrl,
        method:             "PATCH",
        body:               payload,
        target_id:          String(itemIdRaw),
        dedup_key:          `update:${form.dataset.itemUrl}`,
      });
      window.AgendaMutationQueue.flush();
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

      const mid = window.AgendaMutationQueue.newMutationId();
      window.AgendaMutationQueue.enqueue({
        client_mutation_id: mid,
        kind:               "restore",
        url,
        method:             "POST",
        dedup_key:          `restore:${form.dataset.itemUrl}`,
      });
      window.AgendaMutationQueue.flush();
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

      const itemIdRaw = $(".add-item-id", form).value;
      const itemEl = findItemEl(itemIdRaw);
      itemEl?.classList.add("is-pending-delete");
      const deleteUrl = `${form.dataset.itemUrl}?scope=${scope}`;
      closeModal();

      if (!itemIdRaw) return;
      // Write-FIRST: optimistically remove from the store + queue the
      // DELETE. The row vanishes instantly from every subscribed view
      // (no waiting on round-trip); the queue handles the actual
      // server call. On any 4xx the dropped-bucket banner surfaces.
      const mid = window.AgendaMutationQueue.newMutationId();
      window.AgendaStore.removeItem(String(itemIdRaw));
      window.AgendaMutationQueue.enqueue({
        client_mutation_id: mid,
        kind:               "destroy",
        url:                deleteUrl,
        method:             "DELETE",
        target_id:          String(itemIdRaw),
        dedup_key:          `delete:${form.dataset.itemUrl}`,
      });
      window.AgendaMutationQueue.flush();
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
  // ---------- agenda visibility filter ----------
  // Filter state lives on the SERVER (AgendaPreference) so a toggle on
  // one device propagates to every other. The first paint uses a
  // localStorage cache (for instant render before the server fetch
  // returns) and we PATCH any change back, which fans out a Monitor
  // broadcast — see subscribeMonitor's `received` handler.
  const PREFS_CACHE_KEY = "agendaPreferencesCache:v1";
  const COMPLETED_GRACE_MS = 5000;

  function defaultPrefs() {
    return {
      hidden_agenda_ids:     [],
      hidden_schedule_ids:   [],
      hidden_schedule_names: {},
      hidden_item_ids:       [],
      hidden_item_names:     {},
      hidden_name_patterns:  [],
      hide_completed:        { task: false, event: false, trigger: false },
      hide_tentative:        false,
    };
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
      hidden_agenda_ids:     Array.isArray(prefs.hidden_agenda_ids) ? prefs.hidden_agenda_ids.map(String) : [],
      hidden_schedule_ids:   Array.isArray(prefs.hidden_schedule_ids) ? prefs.hidden_schedule_ids.map(String) : [],
      hidden_schedule_names: Object.assign({}, prefs.hidden_schedule_names || {}),
      hidden_item_ids:       Array.isArray(prefs.hidden_item_ids) ? prefs.hidden_item_ids.map(String) : [],
      hidden_item_names:     Object.assign({}, prefs.hidden_item_names || {}),
      hidden_name_patterns:  Array.isArray(prefs.hidden_name_patterns) ? prefs.hidden_name_patterns.slice() : [],
      hide_completed:        Object.assign({ task: false, event: false, trigger: false }, prefs.hide_completed || {}),
      hide_tentative:        !!prefs.hide_tentative,
    };
    persistPrefsCache();
    syncFilterPanelToPrefs();
    applyAgendaVisibility();
    syncDetailsHideRecurring(detailsModalItem);
  }
  function pushPrefsToServer() {
    persistPrefsCache();
    return ajax("PATCH", "/agenda_preference", {
      agenda_preference: {
        hidden_agenda_ids:    currentPrefs.hidden_agenda_ids,
        hidden_schedule_ids:  currentPrefs.hidden_schedule_ids || [],
        hidden_item_ids:      currentPrefs.hidden_item_ids || [],
        hidden_name_patterns: currentPrefs.hidden_name_patterns || [],
        hide_completed:       currentPrefs.hide_completed,
        hide_tentative:       currentPrefs.hide_tentative,
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
    const hiddenSchedules = new Set((currentPrefs.hidden_schedule_ids || []).map(String));
    const hiddenItems = new Set((currentPrefs.hidden_item_ids || []).map(String));
    const completedHidden = currentPrefs.hide_completed;
    const tentativeHidden = currentPrefs.hide_tentative;
    // Compile patterns once per pass. Each pattern always runs case-insensitive
    // ("i" flag); invalid regexes are skipped silently so a bad client-cached
    // entry doesn't break visibility for every row.
    const patterns = (currentPrefs.hidden_name_patterns || []).reduce((acc, src) => {
      try { acc.push(new RegExp(src, "i")); } catch (_) { /* skip */ }
      return acc;
    }, []);
    document.querySelectorAll("[data-agenda-id]").forEach((el) => {
      // The cal-month / cal-week PWA uses its own item classes; keep them
      // in lock-step with the day/week-list classes so the same prefs
      // panel filters every view.
      const filterable = (
        el.classList.contains("agenda-item")
        || el.classList.contains("cal-item")
        || el.classList.contains("cal-month-item")
        || el.classList.contains("cal-month-banner")
        || el.classList.contains("cal-week-event")
        || el.classList.contains("cal-week-allday-chip")
      );
      if (!filterable) return;
      const hideByAgenda = hidden.has(el.dataset.agendaId);
      const scheduleId = el.dataset.agendaScheduleId;
      const hideBySchedule = !!scheduleId && hiddenSchedules.has(String(scheduleId));
      // One-off hide keys on the item's own id. Phantom recurring rows
      // expose a synthetic `p-<schedule>-<date>` id and never match here,
      // so the recurring-vs-one-off paths stay cleanly separated.
      const rawItemId = el.dataset.itemId || "";
      const hideByItem = !!rawItemId && /^\d+$/.test(rawItemId) && hiddenItems.has(rawItemId);
      const name = el.dataset.name || "";
      const hideByPattern = patterns.length > 0 && patterns.some((re) => re.test(name));
      const kind = el.dataset.kind;
      const isCrossedOut = el.classList.contains("crossed-out");
      const itemId = el.dataset.itemId;
      const inGrace = itemId && gracedItemIds.has(itemId);
      const hideByCompleted = isCrossedOut && !!completedHidden[kind] && !inGrace;
      const hideByTentative = tentativeHidden && el.classList.contains("tentative");
      // Declined invites: on the calendar grid we treat them like a
      // user-hidden item — the seed gets pushed into the left gutter as a
      // colored breadcrumb, still clickable for un-decline. Agenda list
      // pages do NOT hide-by-filter; they show the declined event greyed
      // + crossed-out via the `.declined` class on the row (CSS-only).
      const isCalSeed = (
        el.classList.contains("cal-item")
        || el.classList.contains("cal-month-item")
        || el.classList.contains("cal-month-banner")
        || el.classList.contains("cal-week-event")
        || el.classList.contains("cal-week-allday-chip")
        || el.classList.contains("cal-week-seed")
        || el.classList.contains("cal-month-allday-seed")
      );
      const hideByDeclined = isCalSeed && el.classList.contains("declined");
      el.classList.toggle("hidden-by-filter", hideByAgenda || hideBySchedule || hideByItem || hideByPattern || hideByCompleted || hideByTentative || hideByDeclined);
    });
    // Trigger the cal-page layout reflow so lanes reclaim the freed
    // horizontal space LIVE — without this, lanes only widen after the
    // post-modal HTML refresh tick. No-op off cal pages; re-entry guard
    // in agenda_cal.js handles the buildWeekBlocks → applyAgendaVisibility
    // → rebuild cycle.
    window.__rebuildAgendaCalLocal?.();
  }
  // Surfaced so the cal_week / cal_month rebuild path (agenda_cal.js) can
  // reapply filter classes after it tears blocks down and rebuilds from
  // seeds — without that, the local refresh that fires on modal-close
  // erases every `.hidden-by-filter` mark.
  window.__applyAgendaVisibility = applyAgendaVisibility;
  // Same idea for the hidden-events list modal in cal_week — it needs to
  // open the details modal for a hidden row so the user can Unhide. Pass
  // any element whose dataset carries the standard item-* attrs.
  window.__openAgendaDetails = (el) => openDetailsModal(el);
  // Pre-render predicate: would this seed be hidden by the current filter
  // prefs? Used by buildWeekBlocks to drop hidden events BEFORE lane
  // layout so visible blocks reclaim the freed horizontal space. Only
  // covers the prefs that can be determined from seed data alone
  // (agenda, schedule, item, name pattern) — completed/tentative still
  // ride the post-hoc `.hidden-by-filter` path.
  // Pre-render predicate: would this seed land in the GUTTER (still
  // clickable breadcrumb in the cal-week's left gutter, lane reclaims
  // the freed horizontal space)? Only the "Hide event", "Hide
  // recurring", "Hide name pattern", and "Declined invite" paths
  // qualify — agenda-toggle hides are handled by the stronger
  // `__agendaSeedShouldRemove` below so the agenda's events vanish
  // entirely instead of leaving a breadcrumb.
  window.__agendaSeedIsHidden = (seed) => {
    if (!seed) return false;
    const hiddenSchedules = new Set((currentPrefs.hidden_schedule_ids || []).map(String));
    const sId = seed.dataset.agendaScheduleId;
    if (sId && hiddenSchedules.has(String(sId))) return true;
    const hiddenItems = new Set((currentPrefs.hidden_item_ids || []).map(String));
    const rawItemId = seed.dataset.itemId || "";
    if (/^\d+$/.test(rawItemId) && hiddenItems.has(rawItemId)) return true;
    const name = seed.dataset.name || "";
    const patterns = currentPrefs.hidden_name_patterns || [];
    for (const src of patterns) {
      try { if (new RegExp(src, "i").test(name)) return true; }
      catch (_) { /* skip */ }
    }
    // Declined invites read as hidden on cal pages so lane layout reclaims
    // their slot and the gutter painter draws a clickable breadcrumb.
    if (seed.dataset.selfResponse === "declined") return true;
    return false;
  };

  // Agenda-toggle hides are SCOPE-WIDE: "Show Agenda" off → every event
  // in that agenda is completely removed from every view, no gutter
  // breadcrumb, no DOM trace. Callers in buildWeekBlocks and
  // layoutMonthBanners short-circuit on this BEFORE the gutter check
  // above so the item never enters lane layout OR the gutter painter.
  window.__agendaSeedShouldRemove = (seed) => {
    if (!seed) return false;
    const hiddenAgendas = new Set((currentPrefs.hidden_agenda_ids || []).map(String));
    return hiddenAgendas.has(String(seed.dataset.agendaId));
  };

  // Thin pass-through for module-decoupled callers (e.g. month_view.js)
  // that don't own a seed node but need the same agenda-toggle list.
  window.__agendaHiddenAgendaIds = () => currentPrefs.hidden_agenda_ids || [];

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
    renderHiddenScheduleList(panel);
    renderPatternList(panel);
  }

  function renderHiddenScheduleList(panel) {
    const list = panel.querySelector("[data-hidden-schedules-list]");
    if (!list) return;
    list.querySelectorAll(".agenda-filter-removable").forEach((n) => n.remove());

    const scheduleIds = (currentPrefs.hidden_schedule_ids || []).map(String);
    const scheduleNames = currentPrefs.hidden_schedule_names || {};
    const itemIds = (currentPrefs.hidden_item_ids || []).map(String);
    const itemNames = currentPrefs.hidden_item_names || {};

    const empty = list.querySelector("[data-hidden-schedules-empty]");
    if (empty) empty.classList.toggle("hidden", scheduleIds.length + itemIds.length > 0);

    const addRow = (label, kind, key) => {
      const li = document.createElement("li");
      li.className = "agenda-filter-removable";
      const span = document.createElement("span");
      span.className = "agenda-filter-removable-label";
      span.textContent = label;
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "agenda-filter-remove";
      btn.setAttribute("aria-label", "Unhide");
      if (kind === "schedule") btn.dataset.unhideScheduleId = key;
      else btn.dataset.unhideItemId = key;
      btn.textContent = "×";
      li.appendChild(span);
      li.appendChild(btn);
      list.appendChild(li);
    };

    scheduleIds.forEach((id) => addRow(
      (scheduleNames[id] ? `${scheduleNames[id]} (recurring)` : `Schedule #${id}`),
      "schedule",
      id,
    ));
    itemIds.forEach((id) => addRow(itemNames[id] || `Item #${id}`, "item", id));
  }

  function renderPatternList(panel) {
    const list = panel.querySelector("[data-pattern-list]");
    if (!list) return;
    const patterns = currentPrefs.hidden_name_patterns || [];
    list.querySelectorAll(".agenda-filter-removable").forEach((n) => n.remove());
    const empty = list.querySelector("[data-pattern-empty]");
    if (empty) empty.classList.toggle("hidden", patterns.length > 0);
    patterns.forEach((src) => {
      const li = document.createElement("li");
      li.className = "agenda-filter-removable";
      const label = document.createElement("span");
      label.className = "agenda-filter-removable-label agenda-filter-pattern-code";
      label.textContent = src;
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "agenda-filter-remove";
      btn.setAttribute("aria-label", "Remove");
      btn.dataset.removePattern = src;
      btn.textContent = "×";
      li.appendChild(label);
      li.appendChild(btn);
      list.appendChild(li);
    });
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

    // Unhide buttons inside the hidden-recurring + pattern lists, plus the
    // pattern add form. Listed at the panel scope (click + submit) so the
    // dynamically-rendered rows don't need their own handlers.
    panel.addEventListener("click", (e) => {
      const unhideSchedBtn = e.target.closest("[data-unhide-schedule-id]");
      if (unhideSchedBtn) {
        e.preventDefault();
        const id = String(unhideSchedBtn.dataset.unhideScheduleId);
        const ids = new Set((currentPrefs.hidden_schedule_ids || []).map(String));
        ids.delete(id);
        currentPrefs.hidden_schedule_ids = Array.from(ids);
        if (currentPrefs.hidden_schedule_names) delete currentPrefs.hidden_schedule_names[id];
        syncFilterPanelToPrefs();
        applyAgendaVisibility();
        syncDetailsHideRecurring(detailsModalItem);
        pushPrefsToServer();
        return;
      }
      const unhideItemBtn = e.target.closest("[data-unhide-item-id]");
      if (unhideItemBtn) {
        e.preventDefault();
        const id = String(unhideItemBtn.dataset.unhideItemId);
        const ids = new Set((currentPrefs.hidden_item_ids || []).map(String));
        ids.delete(id);
        currentPrefs.hidden_item_ids = Array.from(ids);
        if (currentPrefs.hidden_item_names) delete currentPrefs.hidden_item_names[id];
        syncFilterPanelToPrefs();
        applyAgendaVisibility();
        syncDetailsHideRecurring(detailsModalItem);
        pushPrefsToServer();
        return;
      }
      const removePatternBtn = e.target.closest("[data-remove-pattern]");
      if (removePatternBtn) {
        e.preventDefault();
        const src = removePatternBtn.dataset.removePattern;
        currentPrefs.hidden_name_patterns = (currentPrefs.hidden_name_patterns || []).filter((p) => p !== src);
        syncFilterPanelToPrefs();
        applyAgendaVisibility();
        pushPrefsToServer();
      }
    });

    const patternForm = panel.querySelector("[data-pattern-form]");
    patternForm?.addEventListener("submit", (e) => {
      e.preventDefault();
      const input = patternForm.querySelector("[data-pattern-input]");
      const err = patternForm.querySelector("[data-pattern-error]");
      const src = (input?.value || "").trim();
      if (err) { err.classList.add("hidden"); err.textContent = ""; }
      if (!src) return;
      try { new RegExp(src, "i"); }
      catch (rex) {
        if (err) { err.textContent = `Invalid regex: ${rex.message}`; err.classList.remove("hidden"); }
        return;
      }
      const existing = currentPrefs.hidden_name_patterns || [];
      if (existing.includes(src)) {
        if (input) input.value = "";
        return;
      }
      currentPrefs.hidden_name_patterns = existing.concat(src);
      if (input) input.value = "";
      syncFilterPanelToPrefs();
      applyAgendaVisibility();
      pushPrefsToServer();
    });
  }

  // Location classification + clickable rendering for the details modal.
  // URL → opens in a new tab. Address → opens in maps (Apple Maps URL is
  // a universal redirector — Apple devices launch the native app; others
  // fall through to maps.apple.com on the web). Name → text + async
  // contact lookup that appends a clickable address line when matched.
  function locationLooksLikeUrl(text) {
    return /^https?:\/\//i.test(text.trim());
  }
  function locationLooksLikeAddress(text) {
    const t = text.trim();
    if (!t) return false;
    // Starts with a street number (most US/CA addresses) OR contains a
    // digit followed by a comma somewhere (city, state, zip pattern).
    if (/^\d/.test(t)) return true;
    if (/\d.*,/.test(t)) return true;
    return false;
  }
  function mapsHref(text) {
    return `https://maps.apple.com/?q=${encodeURIComponent(text)}`;
  }
  function renderClickableLocation(target, raw) {
    target.textContent = "";
    const text = (raw || "").trim();
    if (!text) return;
    if (locationLooksLikeUrl(text)) {
      const a = document.createElement("a");
      a.href = text;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.textContent = text;
      target.appendChild(a);
      return;
    }
    if (locationLooksLikeAddress(text)) {
      const a = document.createElement("a");
      a.href = mapsHref(text);
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      a.textContent = text;
      target.appendChild(a);
      return;
    }
    // Name path — show the raw text.
    target.appendChild(document.createTextNode(text));
    // Skip the contact-lookup auto-resolve when the surrounding row has
    // its own dedicated resolved-address target. The travel-chain
    // resolver fills `data-resolved-address` directly on the seed and
    // the modal renders that into a sibling span; firing this fetch
    // would just paint the same address a second time nested inside
    // THIS target. (Reproduced as the "Horsetail Falls" event showing
    // the trail address twice underlined.)
    const row = target.closest("[data-loc-row]");
    const hasDedicatedResolved = !!row?.querySelector("[data-loc-resolved-target]");
    if (hasDedicatedResolved) return;
    // Fallback for any future caller that doesn't sit inside the
    // details-modal row layout — async contact lookup so a typed name
    // like "Mom" still resolves to a clickable address.
    fetch(`/contacts/lookup?name=${encodeURIComponent(text)}`, {
      headers: { Accept: "application/json" },
      credentials: "same-origin",
    })
      .then((res) => (res.ok ? res.json() : null))
      .then((data) => {
        if (!data || !data.address) return;
        if (!target.isConnected) return;
        const resolved = document.createElement("span");
        resolved.className = "agenda-details-loc-resolved";
        const a = document.createElement("a");
        a.href = mapsHref(data.address);
        a.target = "_blank";
        a.rel = "noopener noreferrer";
        a.textContent = data.address;
        resolved.appendChild(a);
        target.appendChild(resolved);
      })
      .catch(() => {});
  }

  // Returns { kind, key, isHidden } describing what the details-modal Hide
  // affordance would target for this item. kind: "schedule" for recurring
  // rows, "item" for one-offs. Null when the item can't be hidden (e.g.
  // phantom row missing both schedule id AND a numeric item id).
  function detailsHideTarget(dataEl) {
    if (!dataEl) return null;
    const scheduleId = dataEl.dataset.agendaScheduleId;
    if (dataEl.dataset.recurring === "true" && scheduleId) {
      const hidden = new Set((currentPrefs.hidden_schedule_ids || []).map(String));
      return { kind: "schedule", key: String(scheduleId), isHidden: hidden.has(String(scheduleId)) };
    }
    const itemId = dataEl.dataset.itemId || "";
    if (/^\d+$/.test(itemId)) {
      const hidden = new Set((currentPrefs.hidden_item_ids || []).map(String));
      return { kind: "item", key: itemId, isHidden: hidden.has(itemId) };
    }
    return null;
  }

  // Flips the small "Hide / Unhide" affordance in the details modal to
  // match the current target's filter state. Recurring → hide the whole
  // series; one-off → hide just this row. Hidden entirely for rows that
  // have neither (e.g. unsaved phantoms).
  function syncDetailsHideRecurring(dataEl) {
    const modal = document.getElementById("agenda-item-details");
    const btn = modal?.querySelector("[data-toggle-hide-recurring]");
    if (!btn) return;
    const target = detailsHideTarget(dataEl);
    btn.classList.toggle("hidden", !target);
    if (!target) return;
    const isHidden = target.isHidden;
    const isSeries = target.kind === "schedule";
    const label = btn.querySelector("[data-toggle-hide-recurring-label]");
    if (label) label.textContent = isHidden ? "Unhide" : "Hide";
    const aria = (
      isSeries
        ? (isHidden ? "Unhide this recurring event" : "Hide this recurring event")
        : (isHidden ? "Unhide this event" : "Hide this event")
    );
    btn.setAttribute("aria-label", aria);
    btn.title = aria;
    const icon = btn.querySelector("[data-toggle-hide-recurring-icon]");
    if (icon) {
      icon.classList.toggle("fa-eye-slash", !isHidden);
      icon.classList.toggle("fa-eye", isHidden);
    }
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
      const canEdit = !dataEl.hasAttribute("data-readonly");
      editBtn.classList.toggle("hidden", !canEdit);
    }
    const d = dataEl.dataset;
    const set = (sel, val) => {
      const node = modal.querySelector(sel);
      if (node) node.textContent = val || "";
    };

    const dot = modal.querySelector("[data-agenda-color-target]");
    if (dot) {
      dot.style.background = d.agendaColor || "";
      // Hover-only debug surface: item-id + agenda-id. Stays out of the
      // visible chrome but is one mouseover away when the user needs to
      // grep logs, hit the API, or report a bug. Same payload appears
      // on the edit modal's agenda-pick dot so users land on the same
      // affordance regardless of which surface they opened.
      dot.title = `Item: ${d.itemId || "—"}\nAgenda: ${d.agendaId || "—"}`;
    }
    // Scope --agenda-color on the modal so the Edit button picks up the
    // event's color via the SCSS rule on .agenda-details-foot .af-btn-primary.
    if (d.agendaColor) modal.style.setProperty("--agenda-color", d.agendaColor);
    else modal.style.removeProperty("--agenda-color");
    set("[data-agenda-name-target]", d.agendaName);
    set("[data-name-target]", d.name);

    const start = d.startAt ? new Date(Number(d.startAt) * 1000) : null;
    const end = d.endAt ? new Date(Number(d.endAt) * 1000) : null;
    const isAllDay = d.allDay === "true";
    const dayFmt = (dt) => dt.toLocaleDateString(undefined, { weekday: "short", month: "short", day: "numeric" });
    let whenLabel = "";
    if (isAllDay && start) {
      // `data-end-date` is the INCLUSIVE last-day midnight (see
      // AgendaItem#presentation_attrs + recurrence.js#buildPhantom).
      // Use it directly so a multi-day all-day event reads as
      // "Sun Jun 21 → Tue Jun 23  ·  All day"; a single-day event
      // collapses to just "Sun Jun 21  ·  All day". Times are
      // intentionally omitted — 12:00am – 12:00am is noise for an
      // all-day event.
      const endDateEpoch = Number(d.endDate) || Number(d.startAt);
      const endDt = new Date(endDateEpoch * 1000);
      const sameDay = (
        start.getFullYear() === endDt.getFullYear() &&
        start.getMonth() === endDt.getMonth() &&
        start.getDate() === endDt.getDate()
      );
      whenLabel = sameDay
        ? `${dayFmt(start)} · All day`
        : `${dayFmt(start)} → ${dayFmt(endDt)} · All day`;
    } else if (start) {
      const dayLabel = dayFmt(start);
      let timeLabel = fmtTime(d.startAt);
      if (d.kind === "event" && end) timeLabel += ` – ${fmtTime(d.endAt)}`;
      whenLabel = `${dayLabel} · ${timeLabel}`;
    }
    set("[data-when-target]", whenLabel);

    const locRow = modal.querySelector("[data-loc-row]");
    if (locRow) {
      const hasLoc = !!(d.location && d.location.length);
      locRow.classList.toggle("hidden", !hasLoc);
      const locTarget = locRow.querySelector("[data-loc-target]");
      if (locTarget) renderClickableLocation(locTarget, d.location || "");
      // Resolved address subtext — what the travel-chain resolver landed on
      // ("Costco" → "13123 S 5600 W, Herriman, UT 84096"). Hidden when it
      // matches the raw location (user already typed a full address) or
      // when no resolution happened yet.
      const resolvedTarget = locRow.querySelector("[data-loc-resolved-target]");
      if (resolvedTarget) {
        const resolved = (d.resolvedAddress || "").trim();
        const same = resolved.toLowerCase() === (d.location || "").trim().toLowerCase();
        const show = hasLoc && resolved.length > 0 && !same;
        resolvedTarget.classList.toggle("hidden", !show);
        if (show) renderClickableLocation(resolvedTarget, resolved);
        else resolvedTarget.textContent = "";
      }
    }

    const travelRow = modal.querySelector("[data-travel-row]");
    if (travelRow) {
      const travelMin = parseInt(d.travelMinutes, 10) || 0;
      const arriveEarlyMin = parseInt(d.arriveEarlyMinutes, 10) || 0;
      const visible = travelMin > 0 || arriveEarlyMin > 0;
      travelRow.classList.toggle("hidden", !visible);
      // Same condensed `[clock] Nm + [car] Mm` shape the agenda row uses —
      // each half hides independently so the row collapses to whichever
      // value is set (or both with a `+` between).
      const arriveIcon = travelRow.querySelector("[data-arrive-early-icon]");
      const travelIcon = travelRow.querySelector("[data-travel-icon]");
      const plus       = travelRow.querySelector("[data-travel-plus]");
      arriveIcon?.toggleAttribute("hidden", arriveEarlyMin <= 0);
      travelIcon?.toggleAttribute("hidden", travelMin <= 0);
      plus?.toggleAttribute("hidden", !(arriveEarlyMin > 0 && travelMin > 0));
      const fmtMin = window.AgendaItemRenderer?.fmtMinutes || ((n) => `${n}m`);
      set("[data-arrive-early-target]", arriveEarlyMin > 0 ? fmtMin(arriveEarlyMin) : "");
      set("[data-travel-target]",       travelMin > 0      ? fmtMin(travelMin)      : "");
      const startEpoch = parseInt(d.startAt, 10) || 0;
      const leaveEpoch = startEpoch - (arriveEarlyMin + travelMin) * 60;
      set("[data-leave-at-target]", (visible && startEpoch > 0) ? `→${fmtCalTime(leaveEpoch)}` : "");
    }

    // Post-travel row — populated when the event has a `to:<location>`
    // override and the chain service has computed the outgoing leg.
    const postTravelRow = modal.querySelector("[data-post-travel-row]");
    if (postTravelRow) {
      const postTravelMin = parseInt(d.postTravelMinutes, 10) || 0;
      const postArriveEpoch = parseInt(d.postArriveAtEpoch, 10) || 0;
      const postVisible = postTravelMin > 0;
      postTravelRow.classList.toggle("hidden", !postVisible);
      const fmtMin = window.AgendaItemRenderer?.fmtMinutes || ((n) => `${n}m`);
      set("[data-post-travel-target]",    postVisible ? fmtMin(postTravelMin) : "");
      set("[data-post-arrive-at-target]", (postVisible && postArriveEpoch > 0) ? `→${fmtCalTime(postArriveEpoch)}` : "");
    }

    const recurringRow = modal.querySelector("[data-recurring-row]");
    if (recurringRow) {
      const isRecurring = d.recurring === "true";
      recurringRow.classList.toggle("hidden", !isRecurring);
      set("[data-recurring-target]", isRecurring ? "Recurring" : "");
    }
    syncDetailsHideRecurring(dataEl);

    const notesRow = modal.querySelector("[data-notes-row]");
    if (notesRow) {
      const hasNotes = !!(d.notes && d.notes.length);
      notesRow.classList.toggle("hidden", !hasNotes);
      set("[data-notes-target]", d.notes);
    }

    hydrateRsvp(modal, dataEl);
    syncGoToDate(modal, dataEl);

    if (window.showModal) window.showModal("#agenda-item-details");
  }

  // "Go to date" jumps the current calendar to whatever date the item
  // is on. Hidden when the item's date is already the visible date (or,
  // for the month view, in the visible month) — nothing to go to. The
  // href targets the SAME view the user is currently on so a click from
  // the day page navigates to another day, not a month view.
  function syncGoToDate(modal, dataEl) {
    const btn = modal.querySelector("[data-go-to-date]");
    if (!btn) return;
    const startEpoch = parseInt(dataEl.dataset.startAt, 10) || 0;
    if (!startEpoch) { btn.classList.add("hidden"); return; }
    const target = new Date(startEpoch * 1000);
    const y = target.getFullYear();
    const m = String(target.getMonth() + 1).padStart(2, "0");
    const day = String(target.getDate()).padStart(2, "0");
    const iso = `${y}-${m}-${day}`;

    const root = document.querySelector(".agenda-page");
    const current = (root && root.getAttribute("data-current-date")) || "";
    let href = null;
    let sameView = false;

    if (root?.classList.contains("agenda-cal-month-page")) {
      href = `/agenda/month?month=${y}-${m}`;
      // Month view: hide when the item is already in the visible month.
      const curMatch = current.match(/^(\d{4})-(\d{2})/);
      sameView = !!curMatch && curMatch[1] === String(y) && curMatch[2] === m;
    } else if (root?.classList.contains("agenda-cal-page")) {
      href = `/agenda/grid?date=${iso}`;
      sameView = weekContains(current, iso);
    } else if (root?.classList.contains("agenda-week-page")) {
      href = `/agenda/week?date=${iso}`;
      sameView = weekContains(current, iso);
    } else if (root?.classList.contains("agenda-day-page")) {
      href = `/agenda?date=${iso}`;
      sameView = current === iso;
    }

    if (!href || sameView) {
      btn.classList.add("hidden");
      btn.removeAttribute("href");
    } else {
      btn.classList.remove("hidden");
      btn.setAttribute("href", href);
    }
  }

  // Returns true when `iso` (YYYY-MM-DD) lies in the same 7-day window as
  // `anchor`. Used by the week / cal_week "already on that date?" check.
  function weekContains(anchor, iso) {
    if (!anchor || !iso) return false;
    const a = new Date(`${anchor}T00:00:00`);
    const b = new Date(`${iso}T00:00:00`);
    if (isNaN(a) || isNaN(b)) return false;
    const diffDays = Math.abs(Math.round((b - a) / 86400000));
    return diffDays < 7;
  }

  // Pulls the attendees + self_response payload off the clicked seed and
  // populates the attendee list + RSVP buttons. No-op on non-invite events
  // (zero attendees) and on non-Google agendas (RSVP requires upstream
  // patch). Optimistic UI: the clicked button enters a pending state until
  // the server returns the new metadata; on failure we revert.
  function hydrateRsvp(modal, dataEl) {
    const d = dataEl.dataset;
    const attendees = safeJsonParse(d.attendees, []);
    const organizer = safeJsonParse(d.organizer, null);
    const isGoogle = d.agendaSource === "google";
    const isEvent = d.kind === "event";
    const itemUrl = d.itemUrl || "";
    const selfResp = d.selfResponse || "";

    const attRow = modal.querySelector("[data-attendees-row]");
    const attList = modal.querySelector("[data-attendees-list]");
    const attHead = modal.querySelector("[data-attendees-heading]");
    if (attRow && attList) {
      const hasAnyone = attendees.length > 0 || !!organizer;
      attRow.classList.toggle("hidden", !hasAnyone);
      attList.innerHTML = "";
      if (hasAnyone && attHead) attHead.textContent = `Guests (${attendees.length})`;
      const seen = new Set();
      const pushRow = (a, organizerFlag) => {
        const email = (a.email || "").toLowerCase();
        if (email && seen.has(email)) return;
        if (email) seen.add(email);
        const li = document.createElement("li");
        li.className = "agenda-details-attendee";
        const status = a.response_status || (organizerFlag ? "accepted" : "needsAction");
        li.classList.add(`rsvp-${status}`);
        if (a.self) li.classList.add("is-self");
        if (organizerFlag) li.classList.add("is-organizer");
        const icon = document.createElement("i");
        icon.className = `fa ${rsvpIconClass(status)}`;
        icon.setAttribute("aria-hidden", "true");
        const label = document.createElement("span");
        label.className = "agenda-details-attendee-label";
        label.textContent = a.display_name || a.email || "(no name)";
        const meta = document.createElement("span");
        meta.className = "agenda-details-attendee-meta";
        const metaBits = [];
        if (organizerFlag) metaBits.push("organizer");
        if (a.optional) metaBits.push("optional");
        if (a.self) metaBits.push("you");
        meta.textContent = metaBits.join(" · ");
        li.appendChild(icon);
        li.appendChild(label);
        if (metaBits.length) li.appendChild(meta);
        attList.appendChild(li);
      };
      if (organizer) pushRow({ ...organizer, response_status: "accepted" }, true);
      attendees.forEach((a) => pushRow(a, false));
    }

    const rsvpRow = modal.querySelector("[data-rsvp-row]");
    if (!rsvpRow) return;
    const showRsvp = isGoogle && isEvent && (attendees.length > 0);
    rsvpRow.classList.toggle("hidden", !showRsvp);
    rsvpRow.querySelectorAll("[data-rsvp-action]").forEach((btn) => {
      btn.classList.toggle("is-current", btn.dataset.rsvpAction === selfResp);
      btn.disabled = false;
      btn.classList.remove("is-pending");
    });
    const feedback = rsvpRow.querySelector("[data-rsvp-feedback]");
    if (feedback) {
      feedback.textContent = "";
      feedback.classList.add("hidden");
    }
    if (!showRsvp) return;

    rsvpRow.querySelectorAll("[data-rsvp-action]").forEach((btn) => {
      btn.onclick = (e) => {
        e.preventDefault();
        const next = btn.dataset.rsvpAction;
        submitRsvp(itemUrl, next, btn, dataEl, modal);
      };
    });
  }

  function safeJsonParse(str, fallback) {
    if (!str) return fallback;
    try { return JSON.parse(str); }
    catch (_) { return fallback; }
  }

  function rsvpIconClass(status) {
    switch (status) {
      case "accepted":  return "fa-check-circle";
      case "tentative": return "fa-question-circle";
      case "declined":  return "fa-times-circle";
      default:          return "fa-circle-o";
    }
  }

  // RSVP is intentionally online-only — the response mirrors directly to
  // Google's responseStatus and the server's `sendUpdates=none` flow,
  // and there's no meaningful local optimistic state to surface beyond
  // the immediate button-disable. Offline RSVP would queue, but the
  // round-trip Google patch can't be replayed by the client. Surface a
  // visible "Sending response…" + revert on failure rather than enqueueing.
  function submitRsvp(itemUrl, response, btn, dataEl, modal) {
    if (!itemUrl || !response) return;
    const url = `${itemUrl}/respond`;
    const rsvpRow = modal.querySelector("[data-rsvp-row]");
    const feedback = rsvpRow?.querySelector("[data-rsvp-feedback]");
    rsvpRow?.querySelectorAll("[data-rsvp-action]").forEach((b) => { b.disabled = true; });
    btn.classList.add("is-pending");
    if (feedback) {
      feedback.textContent = "Sending response…";
      feedback.classList.remove("hidden");
    }
    ajax("POST", url, { response: response })
      .then((res) => res.json())
      .then((payload) => {
        // Persist truth onto the clicked seed so subsequent opens of the
        // details modal reflect the new state without a server round-trip.
        dataEl.dataset.selfResponse = payload.self_response || "";
        dataEl.dataset.attendees = JSON.stringify(payload.attendees || []);
        // Sync the row's class markers so the gutter-hide path + agenda
        // list styling match the response immediately.
        dataEl.classList.toggle("declined", payload.declined === true);
        dataEl.classList.toggle("needs-response", payload.needs_response === true);
        if (feedback) {
          feedback.textContent = "";
          feedback.classList.add("hidden");
        }
        btn.classList.remove("is-pending");
        rsvpRow?.querySelectorAll("[data-rsvp-action]").forEach((b) => {
          b.disabled = false;
          b.classList.toggle("is-current", b.dataset.rsvpAction === payload.self_response);
        });
        window.__rebuildAgendaCalLocal?.();
        window.__applyAgendaVisibility?.();
      })
      .catch((err) => {
        btn.classList.remove("is-pending");
        rsvpRow?.querySelectorAll("[data-rsvp-action]").forEach((b) => { b.disabled = false; });
        if (feedback) {
          feedback.textContent = "Couldn't save your response — please try again.";
          feedback.classList.remove("hidden");
        }
        console.warn("[agenda] rsvp failed", err);
      });
  }

  function openAddModalForDate(dateStr) {
    const modal = $("#agenda-add-modal");
    if (!modal) return;
    const dateInput = modal.querySelector(".add-date");
    if (dateInput && dateStr) dateInput.value = dateStr;
    if (window.showModal) window.showModal("#agenda-add-modal");
  }

  // ---------- follow-up modal ----------
  // Mini month picker shown when the user clicks "Follow up" from the
  // edit modal. Reads ALL items directly from AgendaStore — no HTML
  // scraping, no extra HTTP roundtrip, works fully offline since the
  // store already has the visible window. Selecting a day enables
  // Confirm; Confirm hands the source event + chosen date to the add
  // modal's prefill entry point.
  function initFollowUpModal() {
    const modal = document.getElementById("agenda-follow-up-modal");
    if (!modal) return null;
    const monthLabel = modal.querySelector("[data-follow-up-month-label]");
    const prevBtn    = modal.querySelector("[data-follow-up-prev]");
    const nextBtn    = modal.querySelector("[data-follow-up-next]");
    const calMount   = modal.querySelector("[data-follow-up-cal]");
    const detail     = modal.querySelector("[data-follow-up-detail]");
    const confirmBtn = modal.querySelector("[data-follow-up-confirm]");
    const sourceName = modal.querySelector("[data-follow-up-source-name]");
    const sourceMeta = modal.querySelector("[data-follow-up-source-meta]");

    let currentMonth = null;
    let selectedDate = null;
    let itemsByDate = new Map();      // keyed by isoDate → array of items in that day
    let source = null;

    function pad(n) { return String(n).padStart(2, "0"); }
    function isoMonth(d) { return `${d.getFullYear()}-${pad(d.getMonth() + 1)}`; }
    function isoDate(d) {
      return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
    }
    function epochToISO(epoch) {
      const d = new Date(Number(epoch) * 1000);
      return isoDate(d);
    }
    function monthLabelText(monthIso) {
      const [y, m] = monthIso.split("-").map(Number);
      const d = new Date(y, m - 1, 1);
      return d.toLocaleDateString(undefined, { month: "long", year: "numeric" });
    }
    function offsetMonth(monthIso, delta) {
      const [y, m] = monthIso.split("-").map(Number);
      const d = new Date(y, m - 1 + delta, 1);
      return isoMonth(d);
    }

    function setMonth(monthIso) {
      currentMonth = monthIso;
      if (monthLabel) monthLabel.textContent = monthLabelText(monthIso);
      renderFromStore(monthIso);
    }

    // Builds the month grid from AgendaStore directly. Range covers the
    // full visible block (Sun..Sat enclosing the month), matching the
    // legacy server-rendered shape. Nudges AgendaSync to lazy-backfill
    // any items older than the store's currently-loaded window.
    function renderFromStore(monthIso) {
      const [y, m] = monthIso.split("-").map(Number);
      const firstOfMonth = new Date(y, m - 1, 1);
      // beginning_of_week(:sunday) — go back to the most recent Sunday.
      const firstVisible = new Date(firstOfMonth);
      firstVisible.setDate(firstVisible.getDate() - firstVisible.getDay());
      // end_of_month → end_of_week(:sunday)
      const lastOfMonth = new Date(y, m, 0);
      const lastVisible = new Date(lastOfMonth);
      lastVisible.setDate(lastVisible.getDate() + (6 - lastVisible.getDay()));

      const fromIso = isoDate(firstVisible);
      const toIso   = isoDate(lastVisible);
      window.AgendaSync?.ensureRangeLoaded(fromIso, toIso);

      itemsByDate = new Map();
      const state = window.AgendaStore?.getState?.() || { items: {} };
      Object.values(state.items || {}).forEach((it) => {
        if (!it || !it.start_at) return;
        const startISO = epochToISO(it.start_at);
        if (startISO < fromIso || startISO > toIso) return;
        if (!itemsByDate.has(startISO)) itemsByDate.set(startISO, []);
        itemsByDate.get(startISO).push({
          name:        it.name,
          startAt:     Number(it.start_at),
          color:       it.color,
          agendaColor: it.agenda_color,
          allDay:      !!it.all_day,
        });
      });

      const todayISO = isoDate(new Date());
      const grid = document.createElement("div");
      grid.className = "follow-up-cal-grid";
      ["S", "M", "T", "W", "T", "F", "S"].forEach((wd) => {
        const head = document.createElement("div");
        head.className = "follow-up-cal-weekday";
        head.textContent = wd;
        grid.appendChild(head);
      });

      const cursor = new Date(firstVisible);
      while (cursor <= lastVisible) {
        const date = isoDate(cursor);
        const dayItems = itemsByDate.get(date) || [];
        const total = dayItems.length;
        const isOther = (cursor.getMonth() + 1) !== m;
        const isToday = date === todayISO;

        const dayBtn = document.createElement("button");
        dayBtn.type = "button";
        dayBtn.className = "follow-up-cal-day";
        if (isOther) dayBtn.classList.add("other-month");
        if (isToday) dayBtn.classList.add("is-today");
        if (date === selectedDate) dayBtn.classList.add("selected");
        dayBtn.dataset.date = date;

        const num = document.createElement("span");
        num.className = "follow-up-cal-day-num";
        num.textContent = String(cursor.getDate());
        dayBtn.appendChild(num);

        if (total > 0) {
          const badge = document.createElement("span");
          badge.className = "follow-up-cal-day-count";
          badge.textContent = String(total);
          dayBtn.appendChild(badge);
        }

        dayBtn.addEventListener("click", () => selectDay(date));
        grid.appendChild(dayBtn);
        cursor.setDate(cursor.getDate() + 1);
      }

      calMount.innerHTML = "";
      calMount.appendChild(grid);
      if (selectedDate && itemsByDate.has(selectedDate)) renderDetail(selectedDate);
    }

    function selectDay(date) {
      selectedDate = date;
      calMount.querySelectorAll(".follow-up-cal-day").forEach((b) => {
        b.classList.toggle("selected", b.dataset.date === date);
      });
      renderDetail(date);
      if (confirmBtn) confirmBtn.disabled = false;
    }

    function renderDetail(date) {
      // The store-driven month build is authoritative — every item in
      // the visible window is already in itemsByDate, no per-day fetch
      // needed. Renders identical output to the old day-HTML scrape.
      const items = itemsByDate.get(date) || [];
      const total = items.length;
      const truncated = 0;

      const d = new Date(date + "T12:00:00");
      const dateLabel = d.toLocaleDateString(undefined, {
        weekday: "short", month: "short", day: "numeric", year: "numeric",
      });

      detail.innerHTML = "";
      const header = document.createElement("div");
      header.className = "follow-up-day-header";
      header.textContent = `${dateLabel} — ${total} event${total === 1 ? "" : "s"}`;
      detail.appendChild(header);

      if (total === 0) {
        const empty = document.createElement("div");
        empty.className = "follow-up-day-empty";
        empty.textContent = "Nothing scheduled.";
        detail.appendChild(empty);
        return;
      }

      const list = document.createElement("ul");
      list.className = "follow-up-day-list";
      const sorted = items.slice().sort((a, b) => a.startAt - b.startAt);
      sorted.forEach((it) => {
        const li = document.createElement("li");
        li.style.setProperty("--item-color", it.agendaColor || it.color || "#666");
        const time = document.createElement("span");
        time.className = "follow-up-day-time";
        time.textContent = it.allDay ? "All day" : fmtTime(it.startAt);
        const name = document.createElement("span");
        name.className = "follow-up-day-name";
        name.textContent = it.name || "(no name)";
        li.appendChild(time);
        li.appendChild(name);
        list.appendChild(li);
      });
      detail.appendChild(list);

      if (truncated > 0) {
        const note = document.createElement("div");
        note.className = "follow-up-day-more";
        note.textContent = `Loading ${truncated} more…`;
        detail.appendChild(note);
      }
    }

    prevBtn?.addEventListener("click", (e) => {
      e.preventDefault();
      if (currentMonth) setMonth(offsetMonth(currentMonth, -1));
    });
    nextBtn?.addEventListener("click", (e) => {
      e.preventDefault();
      if (currentMonth) setMonth(offsetMonth(currentMonth, +1));
    });

    confirmBtn?.addEventListener("click", (e) => {
      e.preventDefault();
      if (!selectedDate || !source) return;
      if (window.hideModal) window.hideModal("#agenda-follow-up-modal");
      advanceToAddModal(source, selectedDate);
    });

    function open(src) {
      source = src;
      selectedDate = null;
      if (confirmBtn) confirmBtn.disabled = true;
      if (sourceName) sourceName.textContent = src.name || "this event";
      if (sourceMeta) sourceMeta.textContent = formatSourceMeta(src);
      detail.innerHTML = `<div class="follow-up-day-empty">Pick a day above to see what's already scheduled.</div>`;
      const startMonth = src.month && /^\d{4}-\d{2}$/.test(src.month)
        ? src.month
        : isoMonth(new Date());
      setMonth(startMonth);
      if (window.showModal) window.showModal("#agenda-follow-up-modal");
    }

    function formatSourceMeta(src) {
      if (!src.date) return "";
      const d = new Date(src.date + "T12:00:00");
      const dateLabel = d.toLocaleDateString(undefined, {
        weekday: "short", month: "short", day: "numeric", year: "numeric",
      });
      if (src.allDay) return `Originally ${dateLabel} · all day`;
      const start = formatTimeStr(src.startTime);
      const end   = formatTimeStr(src.endTime);
      if (start && end && start !== end) return `Originally ${dateLabel} · ${start}–${end}`;
      if (start)                          return `Originally ${dateLabel} · ${start}`;
      return `Originally ${dateLabel}`;
    }

    // "HH:MM" 24h string → "9:00am" / "1:00pm" to match fmtTime's render.
    function formatTimeStr(hhmm) {
      if (!hhmm || !/^\d{1,2}:\d{2}$/.test(hhmm)) return "";
      const [h, m] = hhmm.split(":").map(Number);
      const ampm = h >= 12 ? "pm" : "am";
      const h12 = ((h % 12) || 12);
      return `${h12}:${String(m).padStart(2, "0")}${ampm}`;
    }

    return { open };
  }

  function advanceToAddModal(source, newDate) {
    if (typeof addModalPrefillAndShow !== "function") return;
    // Preserve the source's day-span (start→end delta) when relocating
    // the follow-up to a new start date — applies to both multi-day
    // all-day events and multi-day timed events.
    const sourceEnd = source.endDate || source.alldayEnd;
    addModalPrefillAndShow({
      agendaId:          source.agendaId,
      name:              source.name,
      kind:              source.kind,
      color:             source.color,
      allDay:            source.allDay,
      date:              newDate,
      endDate:           sourceEnd ? shiftAllDayEnd(source.date, sourceEnd, newDate) : newDate,
      startTime:         source.startTime,
      endTime:           source.endTime,
      location:          source.location,
      notes:             source.notes,
      triggerExpression: source.triggerExpression,
    });
  }

  // For multi-day events (all-day or timed) being relocated by the
  // follow-up flow: preserve the source span (day-delta between start
  // and end) when shifting to the chosen day.
  function shiftAllDayEnd(origStart, origEnd, newStart) {
    if (!origStart || !origEnd) return newStart;
    const s = new Date(origStart + "T12:00:00");
    const e = new Date(origEnd + "T12:00:00");
    const days = Math.round((e - s) / 86400000);
    const ns = new Date(newStart + "T12:00:00");
    ns.setDate(ns.getDate() + days);
    const pad = (n) => String(n).padStart(2, "0");
    return `${ns.getFullYear()}-${pad(ns.getMonth() + 1)}-${pad(ns.getDate())}`;
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
        // On reconnect, nudge the queue drain (AgendaMutationQueue's own
        // online/visibility hooks will fire too, but reconnect can lag
        // those events on iOS PWAs) and re-sync the visible view since
        // we likely missed broadcasts while down.
        window.AgendaMutationQueue?.flush();
        const r = $(".agenda-page");
        if (r) refreshCurrentView();
      },
      disconnected: function () {
        window.__agendaMonitorDisconnected = true;
        clearTimeout(disconnectTimer);
        disconnectTimer = setTimeout(() => {
          $(".agenda-error")?.classList.remove("hidden");
        }, DISCONNECT_GRACE_MS);
      },
      received: function (data) {
        // Monitor's dispatcher (dashboard/cells/monitor.js) passes the
        // whole broadcast payload — so the prefs ride at `data.data.preferences`,
        // not `data.preferences`. Reading the wrong key here silently
        // dropped every cross-session pref broadcast.
        const prefs = data?.data?.preferences;
        if (prefs) {
          applyPreferenceSnapshot(prefs);
          return;
        }
        // Broadcasts go out for every agenda the user has access to. The
        // global views render whatever the current user can see, so any
        // accessible-agenda change is a refresh signal — no filtering by id.
        // AgendaStore's own Monitor subscriber (in sync.js) handles the
        // data-side refresh via delta — we just nudge the visible view
        // to re-render in case the broadcast carried no item changes
        // (e.g. preference flip from another device that doesn't fire
        // through the store path).
        const root = $(".agenda-page");
        if (!root) return;
        refreshCurrentView();
      },
    });
  }

  // All views (day, week, month, grid) live-update via AgendaStore on
  // broadcasts — no fragment-fetch / section-swap needed. The previous
  // `refreshView` / `swapDaySections` / `refreshCalendarGrid` path is
  // gone with the server-rendered item HTML it consumed. On Monitor
  // reconnect or page-focus we just nudge the per-view renderer to
  // re-paint from the freshly-synced store.
  function refreshCurrentView() {
    // list_view.js (day/week) and agenda_cal.js (month/grid) each expose
    // a render hook; call whichever is on the page. Both no-op when their
    // page class isn't matched.
    if (typeof window.__refreshAgendaList === "function") window.__refreshAgendaList();
    if (typeof window.__refreshAgendaCal === "function") window.__refreshAgendaCal();
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

    // Returns whether the perceived day changed; applyDateRoll already
    // triggered the per-view re-render, so callers don't need to refresh
    // again if `true`.
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

  // list_view's `__agendaJumpToToday` hook does the full re-stamp (root
  // dataset, prev/next hrefs, per-section data-date, section headers,
  // jump-row visibility, then render). Delegating avoids duplicating
  // that contract here and — crucially — re-stamps week-view's
  // per-section `data-date` which the old inline body missed. Cal views
  // never reach here (guarded at the scheduleAutoDateAdvance call site);
  // they own their own rollover via agenda_cal.js's handleDayRollover.
  function applyDateRoll(_root, _newDateIso) {
    if (typeof window.__agendaJumpToToday === "function") {
      window.__agendaJumpToToday();
    }
  }

  document.addEventListener("DOMContentLoaded", () => {
    const root = $(".agenda-page");
    if (!root) return;
    const addModal = $("#agenda-add-modal");
    if (addModal) initAddModal(addModal);
    followUpAPI = initFollowUpModal();
    initEdit(root);
    initAgendaFilter();
    initChecks(root);
    // Wire the dismiss button on the permanent-failure banner. The
    // mutation queue owns the dropped bucket; we just trigger its clear.
    document.querySelector(".agenda-error-dropped .agenda-error-dismiss")?.addEventListener("click", () => {
      window.AgendaMutationQueue?.dismissDropped();
    });
    updateDroppedBanner();
    updatePendingBadge();
    window.AgendaMutationQueue?.subscribe(() => {
      updatePendingBadge();
      updateDroppedBanner();
    });
    // The list-view rollover machinery only knows list DOM (date-label,
    // section headers, prev/next). Cal views (agenda-cal-*-page) own
    // their own rollover in agenda_cal.js's scheduleDayRollover — don't
    // double-schedule here, and don't corrupt their `data-current-date`
    // (which for cal_month is a YYYY-MM-01 month anchor, not a day).
    const isListView = root.matches(".agenda-day-page, .agenda-week-page");
    const checkRollover = isListView ? scheduleAutoDateAdvance(root) : null;

    // Foreground re-sync — mobile browsers suspend the ActionCable socket
    // while backgrounded and may miss broadcasts. The mutation queue's
    // own visibility hook will drain too; we keep the rollover check
    // co-located so the 3am date roll still fires when the tab wakes.
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState !== "visible") return;
      if (checkRollover) checkRollover();
    });

    subscribeMonitor();

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
