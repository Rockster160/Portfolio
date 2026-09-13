// A list broadcast carries the WHOLE list, so whichever one lands last is what
// the page shows. ActionCable dispatches each broadcast on its own worker-pool
// thread (four by default), so snapshots published milliseconds apart — three
// items added in a row — can arrive in any order, and the one-item snapshot
// overtaking the three-item one leaves items missing until something else bumps
// the list.
//
// `timestamp` on the payload is milliseconds, stamped server-side after the
// read that produced the snapshot, so it orders the snapshots by how fresh
// their data is. Drop anything older than what has already been drawn.
//
// One gate per subscription: a fresh subscription re-fetches from scratch, and
// carrying the old high-water mark across would silently swallow the first
// snapshot after a reconnect.
export function snapshotGate() {
  let drawn = -Infinity;

  return function (stamp) {
    const ts = Number(stamp);
    // Unstamped payloads are not from this race — nothing to order them by, so
    // they go through rather than being dropped on a NaN comparison.
    if (!Number.isFinite(ts)) return true;
    if (ts < drawn) return false;

    drawn = ts;
    return true;
  };
}
