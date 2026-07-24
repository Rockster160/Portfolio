// localStorage-backed per-conversation message history cache. Persists
// every message broadcast by the server so an offline / cold-open reload
// can render the thread instantly from cache.
//
// Keyed by conversation id — switching conversations swaps the entire
// working set without touching the others' caches.

const KEY_PREFIX = "byte:messages:v2:";
// Legacy key (pre-multi-conversation). Read once to seed the primary
// conversation's cache on first migration; never written back.
const LEGACY_KEY = "byte:messages:v1";
const MAX_HISTORY = 50;

function keyFor(convId) { return `${KEY_PREFIX}${convId}`; }

export function loadMessages(convId) {
  if (convId == null) return [];
  try {
    const raw = JSON.parse(localStorage.getItem(keyFor(convId)) || "null");
    if (Array.isArray(raw)) return raw;
  } catch (e) {}
  return [];
}

// Read the pre-multi-convo cache if present. Callers that want the seed
// use this once at startup for the default conversation; do NOT rely on
// it for arbitrary conversations.
export function readLegacyCache() {
  try {
    const raw = JSON.parse(localStorage.getItem(LEGACY_KEY) || "null");
    return Array.isArray(raw) ? raw : [];
  } catch (e) {
    return [];
  }
}

export function clearLegacyCache() {
  try { localStorage.removeItem(LEGACY_KEY); } catch (e) {}
}

export function persistMessages(convId, list) {
  if (convId == null) return;
  const trimmed = Array.isArray(list) ? list.slice(-MAX_HISTORY) : [];
  try {
    localStorage.setItem(keyFor(convId), JSON.stringify(trimmed));
  } catch (e) {
    // quota exceeded — swallow; next persist may succeed after trim
  }
}

// Upsert (by id) into an in-memory list and re-persist. Returns the
// mutated list for chaining.
export function upsertPersisted(convId, list, message) {
  const idx = list.findIndex((m) => String(m.id) === String(message.id));
  if (idx >= 0) list[idx] = message;
  else list.push(message);
  persistMessages(convId, list);
  return list;
}

export function clearPersisted(convId) {
  if (convId == null) return;
  try { localStorage.removeItem(keyFor(convId)); } catch (e) {}
}

// Wipe every per-conversation cache (used by /clear meta command).
export function clearAllPersisted() {
  try {
    Object.keys(localStorage)
      .filter((k) => k.startsWith(KEY_PREFIX))
      .forEach((k) => localStorage.removeItem(k));
    clearLegacyCache();
  } catch (e) {}
}
