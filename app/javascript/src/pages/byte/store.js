// localStorage-backed message history cache. Persists every message
// broadcast by the server so an offline / cold-open reload can render
// the thread instantly from cache while the network fetch (if any)
// catches up in the background.
//
// Keyed by message id. Streaming updates replace in-place. Trimmed to
// MAX_HISTORY to stay well below the 5 MB localStorage cap.

const KEY = "byte:messages:v1";
// Only cache the RECENT window locally — older history is one paginated
// fetch away. Keeping this small lets a fresh cold-open paint fast, keeps
// localStorage well under quota, and matches user expectation that the
// PWA "remembers what I just saw" rather than the entire archive.
const MAX_HISTORY = 50;

export function loadMessages() {
  try {
    const raw = JSON.parse(localStorage.getItem(KEY) || "[]");
    return Array.isArray(raw) ? raw : [];
  } catch (e) {
    return [];
  }
}

export function persistMessages(list) {
  const trimmed = Array.isArray(list) ? list.slice(-MAX_HISTORY) : [];
  try {
    localStorage.setItem(KEY, JSON.stringify(trimmed));
  } catch (e) {
    // quota exceeded — swallow; next persist may succeed after trim
  }
}

// Upsert (by id) into an in-memory list and re-persist. Returns the
// mutated list for chaining.
export function upsertPersisted(list, message) {
  const idx = list.findIndex((m) => String(m.id) === String(message.id));
  if (idx >= 0) list[idx] = message;
  else list.push(message);
  persistMessages(list);
  return list;
}

export function clearPersisted() {
  try { localStorage.removeItem(KEY); } catch (e) {}
}
