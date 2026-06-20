// Bridges AgendaStore → the legacy seed DOM that agenda_cal.js's
// buildWeekBlocks / layoutMonthBanners expect to find. Lets us swap
// the data source (was: server-rendered ERB seeds) without rewriting
// the entire downstream rendering pipeline.
//
// The attribute list is NOT declared here — it comes from each item's
// `presentation_attrs` hash (set by `AgendaItem#presentation_attrs` and
// piped through the JSON store as `item.presentation_attrs`). Same hash
// drives `_data_attrs.html.erb`, so the server-rendered and
// client-rendered seeds emit byte-for-byte identical data payloads.

const Store = require("./store");

function escapeAttr(value) {
  if (value === null || value === undefined) return "";
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

function buildWeekSeed(item, _agenda) {
  const attrs = item.presentation_attrs || {};
  const parts = [
    `class="cal-week-seed agenda-item-data"`,
    `data-open-details`,
    item.editable === false ? `data-readonly` : "",
  ];
  for (const key of Object.keys(attrs)) {
    parts.push(`data-${key}="${escapeAttr(attrs[key])}"`);
  }
  return `<div ${parts.filter(Boolean).join(" ")}></div>`;
}

function buildMonthAllDaySeed(item) {
  const attrs = item.presentation_attrs || {};
  const parts = [
    `class="cal-month-allday-seed agenda-item-data"`,
    item.editable === false ? `data-readonly` : "",
  ];
  for (const key of Object.keys(attrs)) {
    parts.push(`data-${key}="${escapeAttr(attrs[key])}"`);
  }
  // Force `data-all-day="true"` regardless of the underlying flag — the
  // banner-layout pass uses this attr as its "is a banner" predicate.
  parts.push(`data-all-day="true"`);
  return `<div ${parts.filter(Boolean).join(" ")}></div>`;
}

// Replace every seed in `container` with freshly-built ones from the
// store's view of `[fromISO..toISO]`. Idempotent — calling twice in a
// row produces the same DOM.
function hydrateWeekSeeds(container, fromISO, toISO) {
  if (!container) return;
  const items = Store.itemsForRange(fromISO, toISO);
  const html = items
    .map((it) => buildWeekSeed(it, Store.getAgenda(it.agenda_id)))
    .join("");
  // innerHTML is fine here — these seeds are PURELY data carriers, the
  // visible blocks are built downstream by buildWeekBlocks and live in
  // separate containers.
  container.innerHTML = html;
}

// Month-view companion: fills the hidden seed container that
// `agenda_cal.js`'s layoutMonthBanners reads to draw row-banner overlays
// for all-day events. Timed events are filtered out — those live in the
// per-cell list owned by `month_view.js`.
function hydrateMonthAllDaySeeds(container, fromISO, toISO) {
  if (!container) return;
  const items = Store.itemsForRange(fromISO, toISO).filter((it) => !!it.all_day);
  container.innerHTML = items.map((it) => buildMonthAllDaySeed(it)).join("");
}

const AgendaSeedHydrator = {
  hydrateWeekSeeds,
  hydrateMonthAllDaySeeds,
  buildWeekSeed,
  buildMonthAllDaySeed,
};

if (typeof module !== "undefined" && module.exports) module.exports = AgendaSeedHydrator;
if (typeof window !== "undefined") window.AgendaSeedHydrator = AgendaSeedHydrator;
