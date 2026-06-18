// Bridges AgendaStore → the legacy seed DOM that agenda_cal.js's
// buildWeekBlocks / layoutMonthBanners expect to find. Lets us swap
// the data source (was: server-rendered ERB seeds) without rewriting
// the entire downstream rendering pipeline.
//
// The output is bit-for-bit the same shape the ERB used to emit, just
// constructed in the browser from the cached AgendaStore snapshot.
// New seed nodes are constructed every call (cheap; the count is the
// number of items in the visible window) so the AgendaStore can be
// the single source of truth — no two-way diffing between DOM and
// store.

const Store = require("./store");

function dataAttr(name, value) {
  // For booleans, ERB used to emit "true"/"false" string. Preserve.
  if (value === true || value === false) return `data-${name}="${value}"`;
  if (value === null || value === undefined) return `data-${name}=""`;
  // Strings + numbers: escape for HTML attribute context.
  const s = String(value)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
  return `data-${name}="${s}"`;
}

function buildWeekSeed(item, agenda) {
  const attrs = [
    `class="cal-week-seed agenda-item-data"`,
    `data-open-details`,
    item.editable === false ? `data-readonly` : "",
    dataAttr("item-id",              item.id),
    dataAttr("item-url",             `/agenda_items/${encodeURIComponent(item.id)}`),
    dataAttr("phantom",              !!item.phantom),
    dataAttr("recurring",            !!item.recurring),
    dataAttr("agenda-schedule-id",   item.agenda_schedule_id || ""),
    dataAttr("kind",                 item.kind || "event"),
    dataAttr("color",                item.color || ""),
    dataAttr("agenda-id",            item.agenda_id || ""),
    dataAttr("agenda-name",          (agenda && agenda.name) || item.agenda_name || ""),
    dataAttr("agenda-color",         (agenda && agenda.color) || item.agenda_color || ""),
    dataAttr("agenda-source",        (agenda && agenda.source) || ""),
    dataAttr("all-day",              !!item.all_day),
    dataAttr("end-date",             endDateEpoch(item)),
    dataAttr("start-at",             item.start_at || ""),
    dataAttr("end-at",               item.end_at || ""),
    dataAttr("name",                 item.name || ""),
    dataAttr("notes",                item.notes || ""),
    dataAttr("location",             item.location || ""),
    dataAttr("arrive-early-minutes", item.arrive_early_minutes || 0),
    dataAttr("travel-minutes",       (item.metadata && Number(item.metadata.travel_minutes)) || 0),
    dataAttr("travel-from-kind",     (item.metadata && item.metadata.travel && item.metadata.travel.travel_from_kind) || ""),
    dataAttr("travel-from",          (item.metadata && item.metadata.travel && item.metadata.travel.travel_from) || ""),
    dataAttr("chain-predecessor-id", (item.metadata && item.metadata.travel && item.metadata.travel.chain_predecessor_id) || ""),
    dataAttr("chain-successor-id",   (item.metadata && item.metadata.travel && item.metadata.travel.chain_successor_id) || ""),
    dataAttr("chain-prev-end-epoch", (item.metadata && item.metadata.travel && item.metadata.travel.chain_prev_end_at) || ""),
    dataAttr("leave-at-epoch",       (item.metadata && item.metadata.travel && item.metadata.travel.leave_at) || ""),
    dataAttr("trigger-expression",   item.trigger_expression || ""),
    dataAttr("schedule",             item.schedule ? JSON.stringify(item.schedule) : ""),
    dataAttr("attendees",            JSON.stringify(item.attendees || [])),
    dataAttr("organizer",            JSON.stringify(item.organizer || null)),
    dataAttr("self-response",        item.self_response || ""),
  ].filter(Boolean).join(" ");
  return `<div ${attrs}></div>`;
}

// For all-day items, the dataset's `end-date` needs to be the epoch of
// the LAST visible day (inclusive). Mirrors AgendaItem#end_date which
// subtracts 1 second for all-day events to render Google's exclusive
// end as an inclusive span.
function endDateEpoch(item) {
  if (!item.end_at) return item.start_at || "";
  if (item.all_day && item.end_at > (item.start_at || 0)) return item.end_at - 1;
  return item.end_at;
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

const AgendaSeedHydrator = {
  hydrateWeekSeeds,
  buildWeekSeed,
};

if (typeof module !== "undefined" && module.exports) module.exports = AgendaSeedHydrator;
if (typeof window !== "undefined") window.AgendaSeedHydrator = AgendaSeedHydrator;
