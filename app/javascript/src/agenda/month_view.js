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
    // Use `itemsForRange` (not state.items) so recurring phantoms render
    // beyond MATERIALIZE_WINDOW. Day-grid cells beyond ~30h of "now" won't
    // have materialized rows yet for daily/weekday standups; the store's
    // expander generates phantoms across the visible month window.
    const grid = root.querySelector(".cal-month-grid[data-month-start][data-month-end]");
    const fromISO = grid?.dataset?.monthStart;
    const toISO = grid?.dataset?.monthEnd;
    const items = (fromISO && toISO)
      ? window.AgendaStore.itemsForRange(fromISO, toISO)
      : Object.values(window.AgendaStore.getState().items || {});
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
    // "Show Agenda" off → the item never enters the per-cell list, so
    // it leaves no `.cal-month-item` DOM trace and no lane gap. Mirrors
    // the same agenda-toggle removal path used by `layoutMonthBanners`
    // and `buildWeekBlocks`.
    const hiddenAgendaIds = collectHiddenAgendaIds();
    items.forEach((item) => {
      if (!item.start_at) return;
      if (item.all_day) {
        // Multi-day all-day events would span buckets; agenda_cal.js
        // handles those as banners, so we skip them entirely here.
        return;
      }
      if (hiddenAgendaIds.has(String(item.agenda_id))) return;
      const dateISO = epochToISO(item.start_at);
      if (!buckets.has(dateISO)) buckets.set(dateISO, []);
      buckets.get(dateISO).push(item);
    });
    return buckets;
  }

  // Mirrors `currentPrefs.hidden_agenda_ids` from agenda.js but reads
  // from a thin global hook so month_view stays decoupled from the
  // bigger module. Falls back to an empty set if the hook isn't loaded
  // yet (e.g. cold boot before agenda.js binds).
  function collectHiddenAgendaIds() {
    const fn = window.__agendaHiddenAgendaIds;
    try { return new Set((fn?.() || []).map(String)); }
    catch (_e) { return new Set(); }
  }

  // Granular diff per cell — mutates existing `.cal-month-item` buttons
  // in place when the same id is already present (no replaceWith → no
  // flicker, no DOM identity churn). Build a fresh button only for
  // genuinely new items; remove only when the item left the cell.
  function diffCells(container, items) {
    const existing = new Map();
    container.querySelectorAll(".cal-month-item[data-item-id]").forEach((el) => {
      existing.set(el.dataset.itemId, el);
    });

    const desiredIds = new Set();
    items.forEach((item) => {
      const id = String(item.id);
      desiredIds.add(id);
      const prev = existing.get(id);
      if (prev) {
        patchCalMonthItem(prev, item);
      } else {
        const node = buildCalMonthItem(item);
        if (node) container.appendChild(node);
      }
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

  // Mutate an existing cell button to match the latest item — same
  // contract as `AgendaItemRenderer.patchAgendaItem`, scoped to the
  // narrower cal_month markup (dot + time + name + optional travel).
  function patchCalMonthItem(btn, item) {
    const attrs = item.presentation_attrs || {};

    for (const key of Object.keys(attrs)) {
      const v = attrs[key];
      const next = v == null ? "" : String(v);
      if (btn.getAttribute(`data-${key}`) !== next) btn.setAttribute(`data-${key}`, next);
    }
    if (btn.getAttribute("data-all-day") !== "false") btn.setAttribute("data-all-day", "false");
    const readonly = item.editable === false;
    if (readonly && !btn.hasAttribute("data-readonly")) btn.setAttribute("data-readonly", "");
    else if (!readonly && btn.hasAttribute("data-readonly")) btn.removeAttribute("data-readonly");

    const color = attrs.color || "";
    const agendaColor = attrs["agenda-color"] || "";
    if (btn.style.getPropertyValue("--item-color") !== color) btn.style.setProperty("--item-color", color);
    if (btn.style.getPropertyValue("--agenda-color") !== agendaColor) btn.style.setProperty("--agenda-color", agendaColor);

    // Re-hydrate the time label after patching — the MutationObserver
    // in agenda.js only fires on added nodes, so an in-place attribute
    // change here would otherwise leave the visible "9a" / "2:30p" text
    // pointing at the previous start_at.
    const timeSpan = btn.querySelector(".cal-month-item-time");
    if (timeSpan) {
      const next = String(attrs["start-at"] || "");
      if (timeSpan.getAttribute("data-start-epoch") !== next) {
        timeSpan.setAttribute("data-start-epoch", next);
      }
      if (typeof window.__hydrateAgendaTimeNode === "function") {
        window.__hydrateAgendaTimeNode(timeSpan);
      }
    }
    const nameSpan = btn.querySelector(".cal-month-item-name");
    if (nameSpan && nameSpan.textContent !== (attrs.name || "")) nameSpan.textContent = attrs.name || "";

    // Travel block toggle (same structural rules as list_view's variant).
    const travelMin = Number(attrs["travel-minutes"]) || 0;
    const arriveMin = Number(attrs["arrive-early-minutes"]) || 0;
    let travelWrap = btn.querySelector(".cal-month-item-travel");
    if (travelMin <= 0 && arriveMin <= 0) {
      if (travelWrap) travelWrap.remove();
      return;
    }
    if (!travelWrap) {
      travelWrap = document.createElement("span");
      travelWrap.className = "cal-month-item-travel";
      btn.appendChild(travelWrap);
    }
    const startEpoch = Number(attrs["start-at"]) || 0;
    const leaveEpoch = startEpoch - (arriveMin + travelMin) * 60;
    // Rebuild travel children — they're small static spans + i tags,
    // cheap to recreate and avoids tracking per-icon presence.
    const fmtMin = window.AgendaItemRenderer?.fmtMinutes || ((n) => `${n}m`);
    travelWrap.innerHTML = `<span class="cal-month-item-travel-leave" data-time-hydrate data-start-epoch="${leaveEpoch}" data-format="cal" data-prefix="→"></span>`;
    if (arriveMin > 0) {
      travelWrap.insertAdjacentHTML("beforeend", `<i class="fa fa-clock-o"></i>${fmtMin(arriveMin)}`);
    }
    if (arriveMin > 0 && travelMin > 0) {
      travelWrap.insertAdjacentHTML("beforeend", '<span class="cal-month-item-travel-plus">+</span>');
    }
    if (travelMin > 0) {
      travelWrap.insertAdjacentHTML("beforeend", `<i class="fa fa-car"></i>${fmtMin(travelMin)}`);
    }
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

      const fmtMin = window.AgendaItemRenderer?.fmtMinutes || ((n) => `${n}m`);
      if (arriveMin > 0) {
        const i = document.createElement("i");
        i.className = "fa fa-clock-o";
        wrap.appendChild(i);
        wrap.appendChild(document.createTextNode(fmtMin(arriveMin)));
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
        wrap.appendChild(document.createTextNode(fmtMin(travelMin)));
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
