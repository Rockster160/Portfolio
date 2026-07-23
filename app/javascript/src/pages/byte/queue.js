// localStorage-backed outbound queue for Byte messages. Every send is
// queued FIRST (state: :queued) and drained by api.drainQueue on the
// nearest opportunity — page load, `online` event, tab focus, or a
// Monitor reconnect. Strict FIFO: on any transient failure the drainer
// stops so message N is never sent before message N-1.
//
// Each entry carries a client-generated `local_id` (UUID) so:
//   * the UI can render the queued bubble before the server has assigned
//     an id, then swap the bubble to the server's id once the response
//     lands;
//   * if the drainer retries mid-round-trip, the server can (later) treat
//     a repeat with the same local_id as idempotent.

const KEY = "byte:outbound_queue:v1";

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

export function enqueue(entry) {
  const q = read();
  q.push({
    local_id:  entry.local_id,
    body:      entry.body,
    metadata:  entry.metadata || {},
    queued_at: Date.now(),
    attempts:  0,
  });
  write(q);
}

export function all() {
  return read();
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
