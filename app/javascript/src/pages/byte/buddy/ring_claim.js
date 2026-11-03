// One sound per ring running out, however many screens are showing it.
//
// Every screen with a feed's rings on it sees the same ring reach zero, and a
// page that reloads sees it again, so playing on sight played it once per
// screen per load. Instead each screen asks the server to CLAIM the sounding
// (POST /ring_claims) and only the one that wins plays it.
//
// A sounding is the feed's owner, the ring's key, the moment it ran out, and
// which repeat it is: 0 the moment it runs out, then one more every five
// minutes while it stays overdue.
//
// A hidden page never claims - it would win the sound and nobody would hear it.
// If the server can't be reached, the claim is retried; after FALLBACK_MS of
// that the screen plays anyway, at most once per device, because a silent alarm
// is worse than a doubled one.

export const REPEAT_SECONDS = 5 * 60;
const RETRY_MS = 5000;
const FALLBACK_MS = 30000;
const PLAYED_PREFIX = "ring-played:";

const settled = new Set();
const inflight = new Set();
const retryAt = new Map();
const failingSince = new Map();

export function soundingSlot(next, nowSec) {
  return Math.floor((nowSec - next) / REPEAT_SECONDS);
}

function playedHere(id) {
  try {
    return window.localStorage.getItem(PLAYED_PREFIX + id) !== null;
  } catch (_) {
    return false;
  }
}

function markPlayedHere(id) {
  try {
    window.localStorage.setItem(PLAYED_PREFIX + id, String(Date.now()));
  } catch (_) {}
}

function claim({ ownerId, key, next, slot }) {
  return fetch("/ring_claims", {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", Accept: "application/json" },
    body: JSON.stringify({ owner_id: ownerId ?? 0, key, at: next, slot }),
  }).then((res) => {
    if (!res.ok) throw new Error(`ring claim failed: ${res.status}`);
    return res.json();
  });
}

// Called every tick for each overdue ring. Plays `play` at most once per
// sounding across every screen.
export function soundOnce({ ownerId, key, next, nowSec }, play, nowMs = Date.now()) {
  if (next === undefined || next === null) return;

  const slot = soundingSlot(next, nowSec);
  if (slot < 0) return;

  const id = `${ownerId ?? ""}:${key}:${next}:${slot}`;
  if (settled.has(id) || inflight.has(id)) return;
  if ((retryAt.get(id) || 0) > nowMs) return;
  if (document.visibilityState !== "visible") return;

  const sound = () => {
    if (playedHere(id)) return;
    markPlayedHere(id);
    play();
  };

  inflight.add(id);
  claim({ ownerId, key, next, slot })
    .then((answer) => {
      settled.add(id);
      if (answer?.play) sound();
    })
    .catch(() => {
      const since = failingSince.get(id) || nowMs;
      failingSince.set(id, since);
      if (nowMs - since >= FALLBACK_MS) {
        settled.add(id);
        sound();
      } else {
        retryAt.set(id, nowMs + RETRY_MS);
      }
    })
    .finally(() => inflight.delete(id));
}
