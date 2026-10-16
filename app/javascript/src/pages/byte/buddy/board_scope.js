// A board watches groups (its chore_tags) and shows only the things in those
// groups — chores, routines and credit buttons do this server-side already.
// The Whisper feeds (duration rings, sounds, standing alerts) are scoped the
// same way: each carries its own groups, and a board shows it only when they
// overlap what the board watches. The overlap is "any", case-insensitive, like
// the chore board's.
//
// The deliberate default: a feed with NO groups matches NO board. Nothing
// leaks onto every board — a thing is shown only where it was aimed.

// The groups this board watches, lower-cased for matching. [] off a board.
export function boardTags(app) {
  try {
    return JSON.parse(app?.dataset?.boardTags || "[]").map((t) => String(t).toLowerCase());
  } catch (e) {
    return [];
  }
}

// Normalise a feed's groups, which may arrive as an array or a comma string.
function normGroups(value) {
  if (Array.isArray(value)) return value.map((g) => String(g).toLowerCase());
  if (typeof value === "string") {
    return value.split(",").map((g) => g.trim().toLowerCase()).filter(Boolean);
  }
  return [];
}

// Does a feed aimed at `feedGroups` belong on a board watching `tags`?
export function groupsOverlap(feedGroups, tags) {
  const groups = normGroups(feedGroups);
  if (groups.length === 0 || !Array.isArray(tags) || tags.length === 0) return false;
  const watched = new Set(tags);
  return groups.some((g) => watched.has(g));
}

// The user who OWNS this board, which is who its feeds have to belong to — not
// whoever is looking at it. A shared board stays its owner's, so it keeps the
// owner's Whisper feeds when a housemate opens it; a board the housemate owns,
// watching the same group name, never picks the owner's feeds up. [] off a board.
export function boardOwnerId(app) {
  const raw = app?.dataset?.boardOwnerId;
  const n = raw == null || raw === "" ? NaN : parseInt(raw, 10);
  return Number.isNaN(n) ? null : n;
}

// Does a feed stamped with `feedOwnerId` belong on a board owned by `boardOwner`?
// An unstamped feed (no owner) and a board with no known owner both fall back to
// the group match alone, so nothing that isn't about ownership changes.
export function feedOwnerMatches(feedOwnerId, boardOwner) {
  if (feedOwnerId == null || boardOwner == null) return true;
  return Number(feedOwnerId) === Number(boardOwner);
}
