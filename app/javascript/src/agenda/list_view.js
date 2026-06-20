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
    window.AgendaStore.hydrateFromLocal();
    window.AgendaStore.subscribe((reason) => {
      if (reason === "hydrate") return; // already painted below
      render(root);
    });
    window.AgendaSync.subscribeMonitor();
    window.AgendaSync.installResumeTriggers();
    window.AgendaSync.boot().then(() => render(root));
    render(root);
    installNavInterception(root);
    window.addEventListener("popstate", () => {
      const params = new URLSearchParams(window.location.search);
      const dateISO = params.get("date") || todayISO();
      renderForDate(root, dateISO);
    });
    // No cold-start blocking indicator — empty sections naturally show
    // their "Nothing scheduled" empty hint while the first sync lands
    // (sub-second window in practice). Any in-flight sync state lives
    // subtly in `.agenda-pending-badge` (header).
    window.__refreshAgendaList = () => render(root);
  }

  // Same-view nav (prev/next day, "Jump to Today") is pure client-side:
  // update the URL, re-stamp date data attributes on root + sections, then
  // re-render from AgendaStore. Cross-view links (.cal-toggle-btn) hit
  // different shells so we let them navigate normally. Without this, every
  // arrow click was a full page reload — and the PWA service worker's
  // shell cache served the same /agenda HTML regardless of `?date=...`,
  // so the URL changed but the page stayed pinned on today.
  function installNavInterception(root) {
    root.addEventListener("click", (e) => {
      const link = e.target.closest(
        ".date-nav.prev, .date-nav.next, .agenda-jump-today"
      );
      if (!link) return;
      const href = link.getAttribute("href");
      if (!href || href.startsWith("#")) return;
      let url;
      try { url = new URL(href, window.location.origin); }
      catch (_) { return; }
      // Only same-pathname (same view) qualifies for client-side.
      if (url.pathname !== window.location.pathname) return;
      e.preventDefault();
      const dateISO = url.searchParams.get("date") || todayISO();
      history.pushState(null, "", url.href);
      renderForDate(root, dateISO);
    });
  }

  // Re-stamp every date-bearing attribute on the shell (root + sections +
  // date label + prev/next hrefs + jump-row visibility) so the next
  // `render()` reads them as if the page had been server-rendered for
  // `dateISO`. The shell never gets re-rendered — only the data
  // attributes change, then list_view's normal render pass paints the
  // store-backed sections.
  function renderForDate(root, dateISO) {
    root.dataset.currentDate = dateISO;

    const dateLabel = root.querySelector(".agenda-date-bar .date-label");
    if (dateLabel) {
      dateLabel.textContent = labelFor(dateISO);
    }

    const isDayView = root.classList.contains("agenda-day-page");
    const basePath = isDayView ? "/agenda" : "/agenda/week";
    const prevLink = root.querySelector(".date-nav.prev");
    const nextLink = root.querySelector(".date-nav.next");
    if (prevLink) prevLink.setAttribute("href", `${basePath}?date=${addDays(dateISO, -1)}`);
    if (nextLink) nextLink.setAttribute("href", `${basePath}?date=${addDays(dateISO, +1)}`);

    // Jump-to-today row: visible unless dateISO === today
    const today = todayISO();
    const jumpRow = root.querySelector(".agenda-jump-row");
    if (jumpRow) jumpRow.classList.toggle("hidden", dateISO === today);

    // Sections: section-today is offset 0, section-tomorrow is offset 1
    // for day view; week view uses offsets 0..7. Stamp data-date on each
    // and update the header label.
    const dayViewLabels = (offset) => {
      if (dateISO === today) return offset === 0 ? "Today" : "Tomorrow";
      const d = addDays(dateISO, offset);
      return d === today ? "Today" : labelFor(d, /* short */ true);
    };
    const weekViewLabels = (offset) => {
      const d = addDays(dateISO, offset);
      if (offset === 0 && dateISO === today) return "Today";
      if (offset === 1 && dateISO === today) return "Tomorrow";
      return labelFor(d, /* short */ true);
    };

    root.querySelectorAll(".agenda-section[data-section-day]").forEach((section) => {
      const offset = parseInt(section.dataset.sectionDay, 10);
      if (Number.isNaN(offset)) return;
      const sectionDate = addDays(dateISO, offset);
      section.dataset.date = sectionDate;
      const labelEl = section.querySelector(".section-header");
      if (labelEl) {
        labelEl.textContent = isDayView ? dayViewLabels(offset) : weekViewLabels(offset);
      }
    });

    render(root);
  }

  function todayISO() {
    const d = new Date();
    const y = d.getFullYear();
    const m = String(d.getMonth() + 1).padStart(2, "0");
    const dd = String(d.getDate()).padStart(2, "0");
    return `${y}-${m}-${dd}`;
  }

  function labelFor(dateISO, short) {
    const d = new Date(`${dateISO}T12:00:00`);
    return d.toLocaleDateString(undefined, short
      ? { weekday: "long", month: "short", day: "numeric" }
      : { weekday: "short", month: "short", day: "numeric", year: "numeric" });
  }

  function render(root) {
    const todayISO = root.dataset.today;
    // Materialized items only — used for the carry-over scan, which is a
    // pure "what tasks are LATE but still active" query and only makes
    // sense for real persisted rows.
    const state = window.AgendaStore.getState();
    const materializedItems = Object.values(state.items || {});

    // For day/week sections we want materialized rows AND recurring
    // phantoms (a weekday standup whose Friday/Monday occurrences sit
    // beyond MATERIALIZE_WINDOW still needs to render). `itemsForRange`
    // is the store's authoritative "what's visible across this window"
    // — it expands schedules + suppresses materialized overrides for us.
    // Without this, navigating into next week showed nothing because
    // `state.items` only carries persisted rows; phantoms live in the
    // recurrence expander and never land in state.items.
    const dates = sectionDates(root);
    const sectionItems = dates.length > 0
      ? window.AgendaStore.itemsForRange(dates[0], dates[dates.length - 1])
      : [];

    // Carry-over: only painted if visible AND we cover today.
    const carrySection = root.querySelector(".section-carry");
    if (carrySection) {
      const coversToday = dates.includes(todayISO);
      const carryItems = coversToday ? carryOver(materializedItems, todayISO) : [];
      paintCarry(carrySection, carryItems);
    }

    // Day sections: each carries a data-date the ERB stamped from the
    // server's view of "what date is this section for". Filter store
    // items per date.
    root.querySelectorAll(".agenda-section[data-section-day]").forEach((section) => {
      const date = section.dataset.date || sectionDateFromOffset(root, section);
      if (!date) return;
      const preview = section.classList.contains("section-tomorrow");
      const dayItems = itemsForDate(sectionItems, date);
      paintDaySection(section, dayItems, { preview: preview });
    });
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

  // Granular DOM diff: keep matching rows by mutating fields in place
  // (no flicker, no focus loss, no scroll jump); only build/insert when
  // an item is genuinely new; only remove when it's gone. The renderer's
  // `patchAgendaItem` is responsible for syncing every visible field
  // and data-* attribute against the latest store snapshot.
  function diffItems(container, items, opts) {
    const existing = new Map();
    container.querySelectorAll(".agenda-item[data-item-id]").forEach((el) => {
      existing.set(el.dataset.itemId, el);
    });

    const desiredIds = new Set();
    items.forEach((item) => {
      const id = String(item.id);
      desiredIds.add(id);
      const prev = existing.get(id);
      if (prev) {
        // In-place patch — keeps the node identity, no DOM lifecycle churn.
        window.AgendaItemRenderer.patchAgendaItem(prev, item, { preview: !!opts.preview });
      } else {
        const node = window.AgendaItemRenderer.buildAgendaItem(item, { preview: !!opts.preview });
        if (node) container.appendChild(node);
      }
    });

    existing.forEach((el, id) => {
      if (!desiredIds.has(id)) el.remove();
    });

    // Reorder to match the sorted desired list — uses `insertBefore` /
    // `prepend` which keep node identity intact (move, not rebuild).
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
      // end_at follows Google's exclusive-next-day-midnight convention,
      // so a 1-day all-day Bday has end_at = tomorrow's midnight epoch.
      // Walk back one second to get the inclusive last-day epoch, then
      // convert to ISO — without this a Bday would render on both today
      // AND tomorrow's sections.
      const startISO = epochToISO(item.start_at);
      const endEpoch = item.end_at || item.start_at;
      const endISO = epochToISO(Number(endEpoch) - 1);
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
