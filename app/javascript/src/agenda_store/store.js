// AgendaStore — single source of truth for the Agenda PWA's client
// state. Mirrors the ChoreStore pattern (hydrate-from-localStorage,
// subscribe(fn), bootstrap/applyDelta, optimistic mutations with
// server-side race guards).
//
// Why this exists:
//   * Every Agenda page (day/week/month/cal_week/cal_month/index)
//     boots an empty shell that hydrates from this store rather than
//     re-rendering ERB server-side on every navigation. Going from
//     "this week" to "three months from now" is a pure in-memory
//     computation: no fetch, no template render, instant paint.
//   * Recurring events are sent down as schedule rules (one per
//     series), not pre-expanded. The store calls Recurrence.expand to
//     materialise phantoms for any visible range — including dates
//     years out — without a server round-trip.
//   * Mutations stay optimistic-first: caller patches the store; the
//     server response reconciles via `server_ts` race guards so a
//     stale broadcast can't undo a fresh local edit.
//
// Persistence: in-memory map + a single localStorage entry under
// "agenda:store:v1". A separate "agenda:lastSyncTs:v1" key holds the
// timestamp delta calls hand to the server. Both keys are versioned so
// a schema change can be rolled out by bumping the suffix; the old key
// is then silently ignored on next hydrate.

const Recurrence = require("./recurrence");
const Tz         = require("./timezone");

const LS_STORE_KEY    = "agenda:store:v1";
const LS_LAST_SYNC_TS = "agenda:lastSyncTs:v1";
const LS_LAST_SYNC_DAY = "agenda:lastSyncDay:v1";

// Bootstrap shape sent by AgendaSyncController#bootstrap. The store
// makes a shallow defensive copy so subsequent mutations can't reach
// back through the caller's reference.
function emptyState() {
  return {
    agendas:               {},  // id -> { id, name, color, slug, source, sort_order, editable, managed_externally }
    schedules:             {},  // id -> serialize_for_client + { editable }
    items:                 {},  // id (string) -> AgendaItem#serialize
    preferences:           null,
    notificationSettings:  {},  // agenda_id -> setting hash
    serverTs:              0,   // ms epoch from the last authoritative payload
    dayKey:                null, // server's perceived-today on last sync
    timezone:              null,
    dayStartHour:          3,
    windowFrom:            null, // ISO date — earliest materialised-item floor known
    carryOverIds:          [],
  };
}

let state = emptyState();
let subscribers = new Set();
let persistTimer = null;

// Persistence -----------------------------------------------------------

function persist() {
  if (typeof window === "undefined" || !window.localStorage) return;
  if (persistTimer) return;
  // Debounce writes a tick — bootstrap/delta apply lots of upserts in a
  // row and we don't need to thrash localStorage between each.
  persistTimer = requestAnimationFrame(() => {
    persistTimer = null;
    try {
      window.localStorage.setItem(LS_STORE_KEY, JSON.stringify(state));
      if (state.serverTs)  window.localStorage.setItem(LS_LAST_SYNC_TS, String(state.serverTs));
      if (state.dayKey)    window.localStorage.setItem(LS_LAST_SYNC_DAY, state.dayKey);
    } catch (err) {
      console.warn("[AgendaStore] persist failed", err);
    }
  });
}

function hydrateFromLocal() {
  if (typeof window === "undefined" || !window.localStorage) return false;
  try {
    const raw = window.localStorage.getItem(LS_STORE_KEY);
    if (!raw) return false;
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") return false;
    state = Object.assign(emptyState(), parsed);
    // Coerce sub-objects in case localStorage came back as null
    state.agendas              = state.agendas              || {};
    state.schedules            = state.schedules            || {};
    state.items                = state.items                || {};
    state.notificationSettings = state.notificationSettings || {};
    notify("hydrate");
    return true;
  } catch (err) {
    console.warn("[AgendaStore] hydrate failed; ignoring local cache", err);
    return false;
  }
}

// Subscribe pattern -----------------------------------------------------

function subscribe(fn) {
  subscribers.add(fn);
  return () => subscribers.delete(fn);
}

function notify(reason, payload) {
  subscribers.forEach((fn) => {
    try { fn(reason, payload); }
    catch (err) { console.warn("[AgendaStore] subscriber error", err); }
  });
}

// Bootstrap / Delta / Page -----------------------------------------------

function applyBootstrap(payload) {
  if (!payload) return;
  state.serverTs     = payload.server_ts     || Date.now();
  state.dayKey       = payload.day_key       || null;
  state.timezone     = payload.timezone      || state.timezone;
  state.dayStartHour = (payload.day_start_hour ?? state.dayStartHour) | 0;
  state.windowFrom   = payload.window && payload.window.from;
  state.carryOverIds = payload.carry_over_ids || [];

  state.agendas    = indexById(payload.agendas    || []);
  state.schedules  = indexById(payload.schedules  || []);
  state.preferences = payload.preferences || state.preferences;
  state.notificationSettings = indexBy(payload.notification_settings || [], "agenda_id");

  // Bootstrap is authoritative for items in `[windowFrom..∞)` — prune
  // anything in the local cache that falls in that range and is NOT in
  // the response. Below the floor we keep whatever the user already
  // had (lazy backfill manages that range).
  const incoming = indexById(payload.items || []);
  if (state.windowFrom) {
    const cutoffEpoch = isoToEpochSecondsFloor(state.windowFrom);
    Object.keys(state.items).forEach((id) => {
      const it = state.items[id];
      const tEnd = (it.end_at || it.start_at || 0);
      if (tEnd >= cutoffEpoch && !incoming[id]) delete state.items[id];
    });
  } else {
    state.items = {};
  }
  Object.assign(state.items, incoming);

  persist();
  notify("bootstrap");
}

function applyDelta(payload) {
  if (!payload) return;
  if (payload.server_ts && payload.server_ts >= state.serverTs) state.serverTs = payload.server_ts;
  state.dayKey = payload.day_key || state.dayKey;
  if (payload.agendas)   state.agendas   = indexById(payload.agendas);
  (payload.schedules || []).forEach((s) => upsertSchedule(s));
  (payload.items     || []).forEach((i) => upsertItem(i));
  persist();
  notify("delta");
}

function applyPage(payload) {
  if (!payload) return;
  if (payload.server_ts && payload.server_ts >= state.serverTs) state.serverTs = payload.server_ts;
  const { from, to } = payload.window || {};
  const incoming = indexById(payload.items || []);
  if (from && to) {
    const lo = isoToEpochSecondsFloor(from);
    const hi = isoToEpochSecondsCeil(to);
    Object.keys(state.items).forEach((id) => {
      const it = state.items[id];
      const start = it.start_at || 0;
      const end   = it.end_at   || start;
      const inWindow = (start <= hi) && (end >= lo);
      if (inWindow && !incoming[id]) delete state.items[id];
    });
  }
  Object.assign(state.items, incoming);
  (payload.schedules || []).forEach((s) => upsertSchedule(s));
  // Track the earliest known materialized floor for lazy-backfill logic.
  if (from && (!state.windowFrom || from < state.windowFrom)) state.windowFrom = from;
  persist();
  notify("page");
}

// Mutations -------------------------------------------------------------

function upsertItem(item, opts) {
  if (!item || !item.id) return;
  const id = String(item.id);
  if (item.status === "cancelled") {
    if (state.items[id]) delete state.items[id];
    return;
  }
  state.items[id] = item;
  if (!opts || opts.persist !== false) persist();
  notify("itemUpsert", item);
}

function removeItem(id) {
  const key = String(id);
  if (!state.items[key]) return;
  delete state.items[key];
  persist();
  notify("itemRemove", { id: key });
}

function upsertSchedule(sched, opts) {
  if (!sched || !sched.id) return;
  state.schedules[sched.id] = sched;
  if (!opts || opts.persist !== false) persist();
  notify("scheduleUpsert", sched);
}

function removeSchedule(id) {
  if (!state.schedules[id]) return;
  delete state.schedules[id];
  persist();
  notify("scheduleRemove", { id });
}

function setPreferences(prefs) {
  state.preferences = prefs;
  persist();
  notify("preferences");
}

// Reads -----------------------------------------------------------------

// Returns AgendaItem-shaped objects (real + phantom) visible in
// [fromISO..toISO]. Phantoms come from expanding every active schedule
// against the range; phantoms shadowed by a materialized override (the
// item carries `original_start_at` matching the phantom date OR a
// matching schedule_id+occurrence date) are suppressed.
function itemsForRange(fromISO, toISO) {
  const tz = state.timezone || guessLocalTimezone();
  const epochAt = (iso) => isoToEpochSecondsFloor(iso);
  const epochEnd = (iso) => isoToEpochSecondsCeil(iso);
  const lo = epochAt(fromISO);
  const hi = epochEnd(toISO);

  const materialized = Object.values(state.items).filter((it) => {
    if (!it || it.status === "cancelled") return false;
    const start = it.start_at || 0;
    const end = it.end_at || start;
    return (start <= hi) && (end >= lo);
  });

  // Map of [schedule_id, dateISO] suppressed by a materialized row.
  // Detached overrides suppress the phantom at their ORIGINAL date so
  // the source occurrence doesn't ghost alongside the relocated edit.
  // Non-detached materialized rows of a recurring series suppress the
  // phantom on the occurrence date they sit on.
  const suppressed = new Set();
  materialized.forEach((it) => {
    if (!it.agenda_schedule_id) return;
    if (it.detached) {
      if (it.original_start_at) {
        suppressed.add(`${it.agenda_schedule_id}:${epochToDateISO(it.original_start_at, tz)}`);
      }
      return;
    }
    suppressed.add(`${it.agenda_schedule_id}:${epochToDateISO(it.start_at, tz)}`);
  });

  const localEpoch = Tz.localEpochFn(tz);
  const phantoms = [];
  Object.values(state.schedules).forEach((sched) => {
    Recurrence.expand(sched, fromISO, toISO).forEach((dateISO) => {
      if (suppressed.has(`${sched.id}:${dateISO}`)) return;
      const ph = Recurrence.buildPhantom(sched, dateISO, { localEpoch });
      // Re-check the produced phantom actually overlaps the window —
      // an event scheduled for 11pm with a duration_minutes that crosses
      // midnight might extend past `to`, which is fine; one anchored at
      // 4am for a 3am-start logical-day might not match.
      const start = ph.start_at || 0;
      const end = ph.end_at || start;
      if ((start <= hi) && (end >= lo)) phantoms.push(ph);
    });
  });

  return materialized.concat(phantoms).sort((a, b) => (a.start_at || 0) - (b.start_at || 0));
}

function getAgendas()              { return Object.values(state.agendas).sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0)); }
function getAgenda(id)             { return state.agendas[id] || null; }
function getItem(id)               { return state.items[String(id)] || null; }
function getSchedule(id)           { return state.schedules[id] || null; }
function getPreferences()          { return state.preferences; }
function getNotificationSetting(agendaId) { return state.notificationSettings[agendaId] || null; }
function getTimezone()             { return state.timezone || guessLocalTimezone(); }
function getDayStartHour()         { return state.dayStartHour || 3; }
function getServerTs()             { return state.serverTs; }
function getWindowFrom()           { return state.windowFrom; }
function getCarryOverIds()         { return state.carryOverIds || []; }
function getDayKey()               { return state.dayKey; }
function snapshot()                { return state; }

function reset() {
  state = emptyState();
  if (typeof window !== "undefined" && window.localStorage) {
    try {
      window.localStorage.removeItem(LS_STORE_KEY);
      window.localStorage.removeItem(LS_LAST_SYNC_TS);
      window.localStorage.removeItem(LS_LAST_SYNC_DAY);
    } catch (err) { /* ignore */ }
  }
  notify("reset");
}

// Day-rollover detection: caller compares stored vs current logical day
// and forces a bootstrap if they differ.
function localDayKey() {
  const tz = getTimezone();
  const now = new Date();
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(now);
  const map = {};
  parts.forEach((p) => { map[p.type] = p.value; });
  return `${map.year}-${map.month}-${map.day}`;
}

function isDayRolledOver() {
  if (!state.dayKey) return false;
  return localDayKey() !== state.dayKey;
}

// Helpers ---------------------------------------------------------------

function indexById(arr) {
  const out = {};
  arr.forEach((r) => { if (r && r.id != null) out[String(r.id)] = r; });
  return out;
}

function indexBy(arr, key) {
  const out = {};
  arr.forEach((r) => { if (r && r[key] != null) out[r[key]] = r; });
  return out;
}

function guessLocalTimezone() {
  try { return Intl.DateTimeFormat().resolvedOptions().timeZone; }
  catch (err) { return "UTC"; }
}

// Wall date 'YYYY-MM-DD' → first second of that day in the store's
// timezone, as epoch seconds. Floor used for range-low side.
function isoToEpochSecondsFloor(iso) {
  return Tz.localEpoch(iso, "00:00", getTimezone());
}

function isoToEpochSecondsCeil(iso) {
  // 23:59:59 of the day in the store's timezone. Used as the upper
  // boundary so an item starting at 11pm of the last day still counts.
  return Tz.localEpoch(iso, "23:59", getTimezone()) + 59;
}

function epochToDateISO(epochSeconds, tz) {
  const dt = new Date(epochSeconds * 1000);
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
  }).formatToParts(dt);
  const map = {};
  parts.forEach((p) => { map[p.type] = p.value; });
  return `${map.year}-${map.month}-${map.day}`;
}

const AgendaStore = {
  // bootstrap/lifecycle
  hydrateFromLocal,
  applyBootstrap,
  applyDelta,
  applyPage,
  reset,
  isDayRolledOver,
  localDayKey,
  // mutations
  upsertItem,
  removeItem,
  upsertSchedule,
  removeSchedule,
  setPreferences,
  // reads
  itemsForRange,
  getAgendas,
  getAgenda,
  getItem,
  getSchedule,
  getPreferences,
  getNotificationSetting,
  getTimezone,
  getDayStartHour,
  getServerTs,
  getWindowFrom,
  getCarryOverIds,
  getDayKey,
  snapshot,
  // subscriptions
  subscribe,
  notify,
  // constants
  LS_STORE_KEY,
  LS_LAST_SYNC_TS,
  LS_LAST_SYNC_DAY,
};

if (typeof module !== "undefined" && module.exports) module.exports = AgendaStore;
if (typeof window !== "undefined") window.AgendaStore = AgendaStore;
