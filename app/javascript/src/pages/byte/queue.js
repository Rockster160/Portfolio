// localStorage-backed outbound queue for Byte messages. One shared queue
// across conversations — each entry carries its own `conversation_id`
// so drain can dispatch to the right thread.
//
// Each entry has a client-generated `local_id` (UUID) so:
//   * the UI can render the queued bubble before the server has assigned
//     an id, then swap the bubble to the server's id once the response
//     lands;
//   * if the drainer retries mid-round-trip, the server can (later) treat
//     a repeat with the same local_id as idempotent.

const KEY = "byte:outbound_queue:v2";
// v1 was a flat array without conversation_id. Read once at boot; the
// caller migrates entries into v2 attributed to the primary conversation
// and clears v1 to prevent double-processing.
const LEGACY_KEY = "byte:outbound_queue:v1";

function read() {
  try {
    const raw = JSON.parse(localStorage.getItem(KEY) || "[]");
    return Array.isArray(raw) ? raw : [];
  } catch (e) {
    return [];
  }
}

function write(q) {
  try { localStorage.setItem(KEY, JSON.stringify(q)); }
  catch (e) {}
}

export function readLegacyQueue() {
  try {
    const raw = JSON.parse(localStorage.getItem(LEGACY_KEY) || "[]");
    return Array.isArray(raw) ? raw : [];
  } catch (e) {
    return [];
  }
}

export function clearLegacyQueue() {
  try { localStorage.removeItem(LEGACY_KEY); } catch (e) {}
}

export function enqueue(entry) {
  const q = read();
  q.push({
    local_id:        entry.local_id,
    conversation_id: entry.conversation_id,
    body:            entry.body,
    metadata:        entry.metadata || {},
    client_ts:       entry.client_ts,
    queued_at:       Date.now(),
    attempts:        0,
  });
  write(q);
}

// Entire queue across every conversation (used by drainQueue).
export function all() {
  return read();
}

// Only entries belonging to a specific conversation (used for hydrating
// the visible thread on load).
export function forConversation(convId) {
  if (convId == null) return [];
  return read().filter((e) => String(e.conversation_id) === String(convId));
}

export function head() {
  return read()[0] || null;
}

export function removeByLocalId(local_id) {
  write(read().filter((e) => e.local_id !== local_id));
}

export function markAttempt(local_id) {
  const q = read();
  const idx = q.findIndex((e) => e.local_id === local_id);
  if (idx < 0) return;
  q[idx] = { ...q[idx], attempts: (q[idx].attempts || 0) + 1, last_attempt_at: Date.now() };
  write(q);
}

export function length() {
  return read().length;
}

export function clearAll() {
  write([]);
  clearLegacyQueue();
}
