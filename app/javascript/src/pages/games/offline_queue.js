// localStorage-backed mutation queue for ONE play at a time. Unlike Timers
// (many endpoints, arbitrary requests queued verbatim) every Games mutation
// lands in the same place - `POST /games/plays/:client_uuid/sync` - so
// what's queued here is the raw roll/score/void/play-patch, and flushing
// coalesces everything pending into one batch. A tap writes to the local
// store AND this queue synchronously, before any network call - that's what
// makes it survive a dead connection.
const QUEUE_KEY = "games:offline_queue:v1";
const STORE_KEY = "games:store:v1";

function readQueue() {
  try {
    return JSON.parse(localStorage.getItem(QUEUE_KEY) || "[]");
  } catch (e) {
    return [];
  }
}

function writeQueue(q) {
  localStorage.setItem(QUEUE_KEY, JSON.stringify(q));
}

export function enqueue(entry) {
  const q = readQueue();
  q.push({ ...entry, queued_at: Date.now() });
  writeQueue(q);
}

export function queueLength() {
  return readQueue().length;
}

// Entries that have been waiting longer than a normal flush takes. Every
// tap is queued and synced ~half a second later, so counting ALL of them
// would flash a "to sync" badge after every single tap.
export function stuckCount(olderThanMs = 4000) {
  const cutoff = Date.now() - olderThanMs;
  return readQueue().filter((e) => (e.queued_at || 0) < cutoff).length;
}

// Batches every queued item under its play's client_uuid into one sync call
// per play. Starting and ending a play are real navigations/form posts (see
// games/new.html.erb, games/finish.html.erb) - only rolls, scores, voids,
// and in-play patches (turn index, player edits) ever land in this queue.
export async function flushQueue({ csrfToken }) {
  const q = readQueue();
  if (q.length === 0) return { flushed: 0 };

  const byPlay = new Map();
  q.forEach((entry) => {
    const bucket = byPlay.get(entry.play_client_uuid) || { play: null, rolls: [], scores: [], voids: [] };
    if (entry.kind === "play") bucket.play = { ...(bucket.play || {}), ...entry.payload };
    if (entry.kind === "roll") bucket.rolls.push(entry.payload);
    if (entry.kind === "score") bucket.scores.push(entry.payload);
    if (entry.kind === "void") bucket.voids.push(entry.payload);
    byPlay.set(entry.play_client_uuid, bucket);
  });

  const headers = { "Content-Type": "application/json", "Accept": "application/json", "X-CSRF-Token": csrfToken };
  const failedPlayUuids = new Set();
  for (const [playUuid, bucket] of byPlay) {
    try {
      const res = await fetch(`/games/plays/${playUuid}/sync`, {
        method: "POST", credentials: "same-origin", headers,
        body: JSON.stringify({ play: bucket.play, rolls: bucket.rolls, scores: bucket.scores, voids: bucket.voids }),
      });
      if (!res.ok && (res.status === 401 || res.status === 403 || res.status >= 500)) failedPlayUuids.add(playUuid);
    } catch (e) {
      failedPlayUuids.add(playUuid);
    }
  }

  const remaining = q.filter((entry) => failedPlayUuids.has(entry.play_client_uuid));
  writeQueue(remaining);
  return { flushed: q.length - remaining.length, remaining: remaining.length };
}

export function saveStoreSnapshot(store) {
  try {
    localStorage.setItem(STORE_KEY, JSON.stringify({ active_play: store.activePlay }));
  } catch (e) { /* quota - ignore */ }
}

export function loadStoreSnapshot() {
  try {
    return JSON.parse(localStorage.getItem(STORE_KEY) || "null");
  } catch (e) {
    return null;
  }
}
