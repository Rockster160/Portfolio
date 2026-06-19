// Month view (cal_month) cell-filler — `agenda_cal.js` already handles
// the all-day banner row layout on store change; this file handles the
// timed-items-in-cells half. Both subscribe to AgendaStore independently
// so each can re-render its own slice on every change.
//
// Cell markup the ERB hands us:
//   <div class="cal-month-cell" data-date="YYYY-MM-DD">
//     ...
//     <div class="cal-month-cell-items" data-items-container></div>
//   </div>
//
// We fill data-items-container with `.cal-month-item` buttons whose
// shape matches what the legacy server-rendered ERB produced — dot,
// time, name, optional travel. all-day items are skipped (banners).

(function () {
  if (typeof window === "undefined") return;

  document.addEventListener("DOMContentLoaded", () => {
    const root = document.querySelector(".agenda-cal-month-page");
    if (!root) return;
    if (!window.AgendaStore || !window.AgendaSync || !window.AgendaItemRenderer) return;
    // AgendaStore boot is owned by agenda_cal.js for the cal pages; we
    // just subscribe so our slice re-renders on each store change.
    if (window.AgendaStore.subscribe) {
      window.AgendaStore.subscribe((reason) => {
        if (reason === "hydrate") render(root); // hydrate IS our cue here
        else render(root);
      });
    }
    render(root);
  });

  function render(root) {
    const state = window.AgendaStore.getState();
    const items = Object.values(state.items || {});
    const byDate = bucketByDate(items);

    root.querySelectorAll(".cal-month-cell[data-date]").forEach((cell) => {
      const container = cell.querySelector(".cal-month-cell-items[data-items-container]");
      if (!container) return;
      const dayItems = (byDate.get(cell.dataset.date) || [])
        .filter((it) => !it.all_day)
        .sort(sortByStart);
      diffCells(container, dayItems);
    });
  }

  function bucketByDate(items) {
    const buckets = new Map();
    items.forEach((item) => {
      if (!item.start_at) return;
      if (item.all_day) {
        // Multi-day all-day events would span buckets; agenda_cal.js
        // handles those as banners, so we skip them entirely here.
        return;
      }
      const dateISO = epochToISO(item.start_at);
      if (!buckets.has(dateISO)) buckets.set(dateISO, []);
      buckets.get(dateISO).push(item);
    });
    return buckets;
  }

  // Granular diff per cell — same shape as list_view.js but builds
  // `.cal-month-item` buttons (compact one-liners) instead of full
  // agenda rows.
  function diffCells(container, items) {
    const existing = new Map();
    container.querySelectorAll(".cal-month-item[data-item-id]").forEach((el) => {
      existing.set(el.dataset.itemId, el);
    });

    const desiredIds = new Set();
    items.forEach((item) => {
      const id = String(item.id);
      desiredIds.add(id);
      const node = buildCalMonthItem(item);
      if (!node) return;
      const prev = existing.get(id);
      if (prev) prev.replaceWith(node);
      else container.appendChild(node);
    });

    existing.forEach((el, id) => {
      if (!desiredIds.has(id)) el.remove();
    });

    let prev = null;
    items.forEach((item) => {
      const id = String(item.id);
      const el = container.querySelector(`.cal-month-item[data-item-id="${cssEscape(id)}"]`);
      if (!el) return;
      if (prev) {
        if (el.previousElementSibling !== prev) prev.after(el);
      } else if (container.firstElementChild !== el) {
        container.prepend(el);
      }
      prev = el;
    });
  }

  // Build the compact cell-row button — different shape from the full
  // `.agenda-item` row that `AgendaItemRenderer` builds, but the same
  // data-* payload (presentation_attrs) for JS hooks (open-details,
  // monitor data, etc.).
  function buildCalMonthItem(item) {
    const attrs = item.presentation_attrs || {};
    const btn = document.createElement("button");
    btn.type = "button";
    btn.className = "cal-month-item agenda-item-data";
    btn.setAttribute("data-open-details", "");
    if (item.editable === false) btn.setAttribute("data-readonly", "");
    for (const key of Object.keys(attrs)) {
      const v = attrs[key];
      btn.setAttribute(`data-${key}`, v == null ? "" : String(v));
    }
    btn.setAttribute("data-all-day", "false");
    btn.style.setProperty("--item-color", attrs.color || "");
    btn.style.setProperty("--agenda-color", attrs["agenda-color"] || "");

    const dot = document.createElement("span");
    dot.className = "cal-month-item-dot";
    dot.setAttribute("aria-hidden", "true");
    btn.appendChild(dot);

    const timeSpan = document.createElement("span");
    timeSpan.className = "cal-month-item-time";
    timeSpan.setAttribute("data-time-hydrate", "");
    timeSpan.setAttribute("data-start-epoch", attrs["start-at"] || "");
    timeSpan.setAttribute("data-format", "cal");
    btn.appendChild(timeSpan);

    const nameSpan = document.createElement("span");
    nameSpan.className = "cal-month-item-name";
    nameSpan.textContent = attrs.name || "";
    btn.appendChild(nameSpan);

    const travelMin = Number(attrs["travel-minutes"]) || 0;
    const arriveMin = Number(attrs["arrive-early-minutes"]) || 0;
    if (travelMin > 0 || arriveMin > 0) {
      const startEpoch = Number(attrs["start-at"]) || 0;
      const leaveEpoch = startEpoch - (arriveMin + travelMin) * 60;
      const wrap = document.createElement("span");
      wrap.className = "cal-month-item-travel";

      const leaveSpan = document.createElement("span");
      leaveSpan.className = "cal-month-item-travel-leave";
      leaveSpan.setAttribute("data-time-hydrate", "");
      leaveSpan.setAttribute("data-start-epoch", leaveEpoch);
      leaveSpan.setAttribute("data-format", "cal");
      leaveSpan.setAttribute("data-prefix", "→");
      wrap.appendChild(leaveSpan);

      if (arriveMin > 0) {
        const i = document.createElement("i");
        i.className = "fa fa-clock-o";
        wrap.appendChild(i);
        wrap.appendChild(document.createTextNode(`${arriveMin}m`));
      }
      if (arriveMin > 0 && travelMin > 0) {
        const plus = document.createElement("span");
        plus.className = "cal-month-item-travel-plus";
        plus.textContent = "+";
        wrap.appendChild(plus);
      }
      if (travelMin > 0) {
        const i = document.createElement("i");
        i.className = "fa fa-car";
        wrap.appendChild(i);
        wrap.appendChild(document.createTextNode(`${travelMin}m`));
      }
      btn.appendChild(wrap);
    }

    return btn;
  }

  function sortByStart(a, b) {
    return (Number(a.start_at) || 0) - (Number(b.start_at) || 0);
  }

  function epochToISO(epoch) {
    const d = new Date(Number(epoch) * 1000);
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const dd = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${dd}`;
  }

  function cssEscape(str) {
    return (window.CSS && window.CSS.escape) ? window.CSS.escape(str) : String(str).replace(/"/g, '\\"');
  }
})();
