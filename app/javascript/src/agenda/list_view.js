// List-view controller — boots AgendaStore on `.agenda-day-page` and
// `.agenda-week-page` shells, subscribes to store changes, and rebuilds
// each section from store items. One layout pass covers both views;
// the only difference is how many day-N sections the ERB renders.
//
// Section markup the ERB hands us (in both views):
//   <section class="agenda-section section-carry hidden" ...>
//     <div class="agenda-items" data-section="carry"></div>
//   </section>
//   <section data-section-day="0" data-date="YYYY-MM-DD">
//     <div class="agenda-items" data-section="day-0"></div>
//   </section>
//   ...etc for day-1, day-2, ... up to day-7 in week view
//
// The renderer (`agenda_item_renderer.js`) clones the item template per
// row; this file owns section grouping, sort, carry-over rule, empty
// state, and granular DOM diff against the previous render.

(function () {
  if (typeof window === "undefined") return;

  document.addEventListener("DOMContentLoaded", () => {
    const root = document.querySelector(".agenda-day-page, .agenda-week-page");
    if (!root) return;
    if (!window.AgendaStore || !window.AgendaSync || !window.AgendaItemRenderer) return;
    init(root);
  });

  function init(root) {
    const hadCache = window.AgendaStore.hydrateFromLocal();
    window.AgendaStore.subscribe((reason) => {
      if (reason === "hydrate") return; // already painted below
      render(root);
    });
    window.AgendaSync.subscribeMonitor();
    window.AgendaSync.installResumeTriggers();
    window.AgendaSync.boot().then(() => render(root));
    render(root);
    if (!hadCache) {
      const cold = root.querySelector("[data-cold-start]");
      if (cold) cold.classList.remove("hidden");
    }
    // Expose a render-trigger for callers that change the visible-date
    // context without mutating the store (3am rollover in agenda.js,
    // ad-hoc date jumps, etc). Pairs with __refreshAgendaCal exposed
    // by agenda_cal.js — agenda.js's refreshCurrentView calls whichever
    // hook is bound on the current page.
    window.__refreshAgendaList = () => render(root);
  }

  function render(root) {
    const todayISO = root.dataset.today;
    const state = window.AgendaStore.getState();
    const items = Object.values(state.items || {});

    // Carry-over: only painted if visible AND we cover today.
    const carrySection = root.querySelector(".section-carry");
    if (carrySection) {
      const coversToday = sectionDates(root).includes(todayISO);
      const carryItems = coversToday ? carryOver(items, todayISO) : [];
      paintCarry(carrySection, carryItems);
    }

    // Day sections: each carries a data-date the ERB stamped from the
    // server's view of "what date is this section for". Filter store
    // items per date.
    root.querySelectorAll(".agenda-section[data-section-day]").forEach((section) => {
      const date = section.dataset.date || sectionDateFromOffset(root, section);
      if (!date) return;
      const preview = section.classList.contains("section-tomorrow");
      const dayItems = itemsForDate(items, date);
      paintDaySection(section, dayItems, { preview: preview });
    });

    const cold = root.querySelector("[data-cold-start]");
    if (cold) cold.classList.add("hidden");
  }

  // Fallback for day view, which has only two sections (today/tomorrow)
  // and doesn't stamp a data-date — derive from the root's current-date.
  function sectionDateFromOffset(root, section) {
    const offset = parseInt(section.dataset.sectionDay, 10);
    if (Number.isNaN(offset)) return null;
    const base = root.dataset.currentDate;
    return base ? addDays(base, offset) : null;
  }

  function sectionDates(root) {
    return Array.from(root.querySelectorAll(".agenda-section[data-section-day]"))
      .map((s) => s.dataset.date || sectionDateFromOffset(root, s))
      .filter(Boolean);
  }

  function paintCarry(section, items) {
    section.classList.toggle("hidden", items.length === 0);
    const countEl = section.querySelector(".section-count");
    if (countEl) countEl.textContent = String(items.length);
    const container = section.querySelector('.agenda-items[data-section="carry"]');
    if (container) diffItems(container, items, {});
  }

  function paintDaySection(section, items, opts) {
    const container = section.querySelector(".agenda-items[data-section]");
    if (!container) return;
    diffItems(container, items, opts);
    const emptyHint = section.querySelector(".agenda-section-empty");
    if (emptyHint) emptyHint.classList.toggle("hidden", items.length > 0);
  }

  // Granular DOM diff: keep matching rows, remove gone, append new,
  // re-order to match the sorted item list. Avoids `innerHTML = ...`
  // so input focus, modal targets, and click handlers on existing
  // rows survive a re-render.
  function diffItems(container, items, opts) {
    const existing = new Map();
    container.querySelectorAll(".agenda-item[data-item-id]").forEach((el) => {
      existing.set(el.dataset.itemId, el);
    });

    const desiredIds = new Set();
    items.forEach((item) => {
      const id = String(item.id);
      desiredIds.add(id);
      const node = window.AgendaItemRenderer.buildAgendaItem(item, { preview: !!opts.preview });
      if (!node) return;
      const prev = existing.get(id);
      if (prev) prev.replaceWith(node);
      else container.appendChild(node);
    });

    existing.forEach((el, id) => {
      if (!desiredIds.has(id)) el.remove();
    });

    // Reorder to match the sorted desired list.
    let prev = null;
    items.forEach((item) => {
      const id = String(item.id);
      const el = container.querySelector(`.agenda-item[data-item-id="${cssEscape(id)}"]`);
      if (!el) return;
      if (prev) {
        if (el.previousElementSibling !== prev) prev.after(el);
      } else if (container.firstElementChild !== el) {
        container.prepend(el);
      }
      prev = el;
    });
  }

  // ---------- date filters ----------

  function itemsForDate(items, dateISO) {
    return items.filter((it) => itemVisibleOn(it, dateISO)).sort(sortByStart);
  }

  // Mirrors `User#agenda_carry_over_items`: kind:task, start_at <
  // today's local midnight, completed_at NULL OR >= today's midnight.
  function carryOver(items, todayISO) {
    const todayMidnight = midnightEpoch(todayISO);
    return items
      .filter((it) => it.kind === "task")
      .filter((it) => Number(it.start_at) < todayMidnight)
      .filter((it) => !it.completed_at || Number(it.completed_at) >= todayMidnight)
      .sort(sortByStart);
  }

  function itemVisibleOn(item, dateISO) {
    if (!item.start_at) return false;
    if (item.all_day) {
      const startISO = epochToISO(item.start_at);
      const endISO = epochToISO(item.end_at || item.start_at);
      return dateISO >= startISO && dateISO <= endISO;
    }
    return epochToISO(item.start_at) === dateISO;
  }

  function sortByStart(a, b) {
    return (Number(a.start_at) || 0) - (Number(b.start_at) || 0);
  }

  // ---------- date helpers ----------

  function midnightEpoch(dateISO) {
    const d = new Date(`${dateISO}T00:00:00`);
    return Math.floor(d.getTime() / 1000);
  }

  function epochToISO(epoch) {
    const d = new Date(Number(epoch) * 1000);
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const dd = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${dd}`;
  }

  function addDays(iso, n) {
    const d = new Date(`${iso}T12:00:00`);
    d.setDate(d.getDate() + n);
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const dd = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${dd}`;
  }

  function cssEscape(str) {
    return (window.CSS && window.CSS.escape) ? window.CSS.escape(str) : String(str).replace(/"/g, '\\"');
  }
})();
