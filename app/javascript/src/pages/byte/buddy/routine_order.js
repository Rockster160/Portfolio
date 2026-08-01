// What the Quick grid and the wall tablet show, and in what order.
//
// Everything switched on, pinned ones first in the order they were dragged
// into, then the rest by name. Mirrors BuddyRoutine.for_quick so the list the
// client rebuilds matches the one the server rendered.
//
// Pinning PROMOTES rather than admits. It used to be the gate, which made
// saving a routine two steps: you'd save one, go looking for it under Quick,
// and find an empty panel telling you to go star it somewhere you weren't. A
// routine you bothered to save is one you want to tap; the star is for putting
// the handful you reach for daily at the front.

// Unpinned sorts after every pinned one without needing a second comparison.
const UNPINNED = Number.MAX_SAFE_INTEGER;

export function quickOrder(routines) {
  return (routines || [])
    .filter((r) => r && r.enabled)
    .sort((a, b) => {
      const ap = a.position == null ? UNPINNED : a.position;
      const bp = b.position == null ? UNPINNED : b.position;
      if (ap !== bp) return ap - bp;
      return String(a.name || "").localeCompare(String(b.name || ""));
    });
}

// Said the same way in both places, because both are reached by someone
// looking for a routine they think they have.
export const NO_ROUTINES = "No routines saved yet — ask to save one.";
