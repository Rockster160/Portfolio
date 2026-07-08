// Agenda Search modal controller. Two-phase search:
//   1. Future / near-past — filtered live from AgendaStore.
//   2. Older past — fetched from /agenda_items/search (only items older
//      than the store's materialised window are pulled — everything after
//      is already in memory).
// Rows are built via AgendaItemRenderer so a search hit looks and behaves
// like the same row in the day/week/month views; clicking one hands off
// to __openAgendaDetails which populates the shared details modal.

(function () {
  if (typeof window === "undefined") return;

  const DEBOUNCE_MS = 180;

  function init() {
    const modal = document.getElementById("agenda-search");
    if (!modal) return;
    // Idempotent — if init runs twice (DOMContentLoaded already fired
    // AND a later ready hook re-invokes us), don't double-bind.
    if (modal.dataset.searchInited === "1") return;
    modal.dataset.searchInited = "1";

    // Scope everything to the modal itself — the inner `.agenda-search`
    // form isn't required as an intermediary anymore. Missing anchors
    // are logged so a silent selector drift is easier to spot in devtools.
    const input      = modal.querySelector("[data-search-input]");
    const idleEl     = modal.querySelector("[data-search-idle]");
    const futureSec  = modal.querySelector('[data-search-section="future"]');
    const pastSec    = modal.querySelector('[data-search-section="past"]');
    const futureList = modal.querySelector('[data-search-items="future"]');
    const pastList   = modal.querySelector('[data-search-items="past"]');
    const futureEmpty= modal.querySelector('[data-search-empty="future"]');
    const pastEmpty  = modal.querySelector('[data-search-empty="past"]');
    const pastStatus = modal.querySelector("[data-search-past-status]");
    const root       = modal.querySelector(".agenda-search") || modal;
    const searchUrl  = root.getAttribute("data-search-url") || "/agenda_items/search";
    if (!input) {
      console.warn("[agenda-search] input not found — search will not work.");
      return;
    }

    let debounceTimer = null;
    let currentQuery  = "";
    let pastFetchId   = 0;

    function reset() {
      currentQuery = "";
      futureList.replaceChildren();
      pastList.replaceChildren();
      futureSec.classList.add("hidden");
      pastSec.classList.add("hidden");
      futureEmpty.classList.add("hidden");
      pastEmpty.classList.add("hidden");
      pastStatus.textContent = "";
      idleEl.classList.remove("hidden");
    }

    function onInput() {
      clearTimeout(debounceTimer);
      const q = input.value.trim();
      if (!q) {
        reset();
        return;
      }
      debounceTimer = setTimeout(() => runSearch(q), DEBOUNCE_MS);
    }

    // Compile a user-typed query into a plain-text matcher for the
    // in-memory pass. `is:` and `kind:` tokens narrow by state/type; the
    // remaining words are ANDed as case-insensitive substring matches
    // across name/notes/location. Mirrors the server dispatch so a query
    // that works on the endpoint also works locally.
    function compileMatcher(q) {
      const tokens = q.split(/\s+/);
      const isFlags = [];
      const kindFlags = [];
      const words = [];
      tokens.forEach((tok) => {
        const m = tok.match(/^(is|kind):(.+)$/i);
        if (!m) { words.push(tok.toLowerCase()); return; }
        const key = m[1].toLowerCase();
        const val = m[2].toLowerCase();
        if (key === "is") isFlags.push(val);
        else kindFlags.push(val.replace(/s$/, ""));
      });

      return (item) => {
        if (!item) return false;
        if (item.status === "cancelled") return false;
        for (const kind of kindFlags) {
          if ((item.kind || "").toLowerCase() !== kind) return false;
        }
        for (const flag of isFlags) {
          if (!matchesIsFlag(item, flag)) return false;
        }
        if (words.length === 0) return true;
        const hay = [item.name, item.notes, item.location].filter(Boolean).join(" ").toLowerCase();
        return words.every((w) => hay.includes(w));
      };
    }

    function matchesIsFlag(item, flag) {
      const now = Math.floor(Date.now() / 1000);
      const start = item.start_at || 0;
      const end = item.end_at || start;
      switch (flag) {
        case "upcoming": return item.kind === "event" ? end >= now : start >= now;
        case "past":     return item.kind === "event" ? end <  now : start <  now;
        case "today": {
          const d = new Date(start * 1000);
          const today = new Date();
          return d.getFullYear() === today.getFullYear()
              && d.getMonth() === today.getMonth()
              && d.getDate() === today.getDate();
        }
        case "recurring":  return !!item.agenda_schedule_id;
        case "completed":
        case "complete":   return !!item.completed_at;
        case "incomplete":
        case "pending":    return !item.completed_at;
        case "overdue":    return item.kind !== "event" && !item.completed_at && start < now;
        case "detached":   return !!item.detached;
        case "task":
        case "event":
        case "trigger":    return item.kind === flag;
        default:           return true;
      }
    }

    // groups keyed by agenda_schedule_id (recurring) or `item-<id>`
    // (one-off). Recurring series collapse to a single row per event —
    // no more "9 copies of Tech Stand-Up" in the results. Repopulated
    // on every keystroke; the past-fetch merges into the same map.
    let groups = new Map();

    function runSearch(q) {
      currentQuery = q;
      idleEl.classList.add("hidden");
      const store = window.AgendaStore;
      const state = store?.getState?.();
      const items = state ? Object.values(state.items || {}) : [];
      const matcher = compileMatcher(q);

      groups = new Map();
      items.filter(matcher).forEach(addToGroups);
      renderGroups();
      fetchPast(q);
    }

    function addToGroups(item) {
      const now = Math.floor(Date.now() / 1000);
      const key = item.agenda_schedule_id ? `sched-${item.agenda_schedule_id}` : `item-${item.id}`;
      let g = groups.get(key);
      if (!g) {
        g = { key, items: [], seen: new Set(), scheduleId: item.agenda_schedule_id || null, futureCount: 0, pastCount: 0 };
        groups.set(key, g);
      }
      const idStr = String(item.id);
      if (g.seen.has(idStr)) return;
      g.seen.add(idStr);
      g.items.push(item);
      if ((item.start_at || 0) >= now) g.futureCount++;
      else g.pastCount++;
    }

    function representative(group) {
      const now = Math.floor(Date.now() / 1000);
      let nextFuture = null;
      let mostRecentPast = null;
      group.items.forEach((it) => {
        const start = it.start_at || 0;
        if (start >= now) {
          if (!nextFuture || start < (nextFuture.start_at || 0)) nextFuture = it;
        } else {
          if (!mostRecentPast || start > (mostRecentPast.start_at || 0)) mostRecentPast = it;
        }
      });
      return nextFuture || mostRecentPast;
    }

    function renderGroups() {
      const withFuture = [];
      const pastOnly   = [];
      groups.forEach((g) => {
        (g.futureCount > 0 ? withFuture : pastOnly).push(g);
      });
      withFuture.sort((a, b) => (representative(a)?.start_at || 0) - (representative(b)?.start_at || 0));
      pastOnly.sort((a, b)  => (representative(b)?.start_at || 0) - (representative(a)?.start_at || 0));

      renderSection(futureSec, futureList, futureEmpty, withFuture);
      renderSection(pastSec,   pastList,   pastEmpty,   pastOnly);
    }

    function fetchPast(q) {
      const before = window.AgendaStore?.getWindowFrom?.();
      if (!before) {
        pastStatus.textContent = "";
        return;
      }
      const fetchId = ++pastFetchId;
      pastStatus.textContent = "Loading older matches…";
      const url = `${searchUrl}?q=${encodeURIComponent(q)}&before=${encodeURIComponent(before)}`;
      fetch(url, { credentials: "same-origin", headers: { Accept: "application/json" } })
        .then((res) => res.ok ? res.json() : Promise.reject(new Error(`HTTP ${res.status}`)))
        .then((body) => {
          if (fetchId !== pastFetchId || q !== currentQuery) return;
          pastStatus.textContent = "";
          (body.items || []).forEach(addToGroups);
          renderGroups();
        })
        .catch(() => {
          if (fetchId !== pastFetchId) return;
          pastStatus.textContent = "Couldn't load older matches.";
        });
    }

    function renderSection(sec, list, emptyEl, groupList) {
      list.replaceChildren();
      if (!groupList.length) {
        sec.classList.add("hidden");
        emptyEl.classList.add("hidden");
        return;
      }
      groupList.forEach((g) => {
        const node = buildGroupRow(g);
        if (node) list.appendChild(node);
      });
      sec.classList.remove("hidden");
      emptyEl.classList.add("hidden");
    }

    // One row per group. Representative = next upcoming occurrence when
    // available, else most-recent past. Subtitle carries the schedule
    // summary (Weekly on Thu, Every 2 weeks…) plus a compact "+N more"
    // occurrence count so a recurring event still hints at its footprint.
    function buildGroupRow(group) {
      const rep = representative(group);
      if (!rep) return null;
      const attrs = rep.presentation_attrs || {};
      const row = document.createElement("div");
      row.className = "agenda-search-hit";
      row.setAttribute("data-readonly", "");
      Object.keys(attrs).forEach((k) => {
        const v = attrs[k];
        row.setAttribute(`data-${k}`, v == null ? "" : String(v));
      });
      row.style.setProperty("--agenda-color", attrs["agenda-color"] || "");

      const body = document.createElement("div");
      body.className = "agenda-search-hit-body";

      const when = document.createElement("div");
      when.className = "agenda-search-hit-when";
      when.textContent = formatWhen(rep);
      body.appendChild(when);

      const name = document.createElement("div");
      name.className = "agenda-search-hit-name";
      name.textContent = rep.name || "(untitled)";
      if (rep.completed_at) name.classList.add("completed");
      body.appendChild(name);

      if (rep.location) {
        const loc = document.createElement("div");
        loc.className = "agenda-search-hit-loc";
        loc.textContent = rep.location;
        body.appendChild(loc);
      }

      const subParts = [];
      const summary = scheduleSummary(rep);
      if (summary) subParts.push(summary);
      const others = (group.futureCount + group.pastCount) - 1;
      if (others > 0) {
        const upcoming = group.futureCount - (rep.start_at >= Math.floor(Date.now() / 1000) ? 1 : 0);
        const past     = group.pastCount   - (rep.start_at <  Math.floor(Date.now() / 1000) ? 1 : 0);
        const bits = [];
        if (upcoming > 0) bits.push(`${upcoming} upcoming`);
        if (past > 0)     bits.push(`${past} past`);
        if (bits.length)  subParts.push(bits.join(", "));
      }
      if (subParts.length) {
        const sub = document.createElement("div");
        sub.className = "agenda-search-hit-sub";
        sub.textContent = subParts.join(" · ");
        body.appendChild(sub);
      }

      row.appendChild(body);
      return row;
    }

    function scheduleSummary(item) {
      if (!item.agenda_schedule_id) return null;
      const sched = window.AgendaStore?.getSchedule?.(item.agenda_schedule_id);
      return describeSchedule(sched);
    }

    // Compact recurrence rule → human string. Covers the four freqs the
    // edit modal exposes; anything exotic falls back to "Recurring" so a
    // partial payload still communicates recurring-ness.
    function describeSchedule(sched) {
      if (!sched) return "Recurring";
      const interval = sched.interval || 1;
      const byDay = (sched.by_day || []).map((d) => String(d).toUpperCase());
      const DAYS = { SU: "Sun", MO: "Mon", TU: "Tue", WE: "Wed", TH: "Thu", FR: "Fri", SA: "Sat" };
      switch (sched.freq) {
        case "daily":
          return interval === 1 ? "Daily" : `Every ${interval} days`;
        case "weekly": {
          const dayLabels = byDay.map((d) => DAYS[d]).filter(Boolean).join(", ");
          const prefix = interval === 1 ? "Weekly" : `Every ${interval} weeks`;
          return dayLabels ? `${prefix} on ${dayLabels}` : prefix;
        }
        case "monthly":
          return interval === 1 ? "Monthly" : `Every ${interval} months`;
        case "yearly":
          return interval === 1 ? "Yearly" : `Every ${interval} years`;
        default:
          return "Recurring";
      }
    }

    function formatWhen(item) {
      const start = item.start_at ? new Date(item.start_at * 1000) : null;
      if (!start) return "";
      const dayFmt = { weekday: "short", month: "short", day: "numeric", year: "numeric" };
      const day = start.toLocaleDateString(undefined, dayFmt);
      if (item.all_day) return `${day} · all day`;
      const time = start.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
      return `${day} · ${time}`;
    }

    // Delegated click: any hit row → hand off to the shared details modal.
    root.addEventListener("click", (e) => {
      const row = e.target.closest("[data-item-id]");
      if (!row) return;
      // Ignore clicks on inline checkbox / edit affordances just in case.
      if (e.target.closest("input, button, a")) return;
      e.preventDefault();
      const opener = window.__openAgendaDetails;
      if (typeof opener !== "function") return;
      if (typeof window.hideModal === "function") window.hideModal("#agenda-search");
      opener(row);
    });

    // Bind both `input` (modern) and `keyup` (belt-and-suspenders) so
    // pasted / IME-composed text still triggers a search even when the
    // browser buffers input events.
    input.addEventListener("input", onInput);
    input.addEventListener("keyup", onInput);

    // Focus the input every time the modal opens so the user can start
    // typing immediately. modals.js triggers "modal.shown" via jQuery
    // after the animation; falling back to a raw event listener keeps
    // this file free of a jQuery dependency.
    if (window.jQuery) {
      window.jQuery(modal).on("modal.shown", () => {
        input.focus();
      });
    }
    modal.addEventListener("modal.shown", () => {
      input.focus();
    });
  }

  // `document.addEventListener("DOMContentLoaded", …)` never fires if the
  // event has already been dispatched — e.g. when this defer'd script
  // finishes evaluation AFTER the document is already interactive. Cover
  // both cases so a slow client / racy load order can't strand the modal
  // with no listeners.
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();
