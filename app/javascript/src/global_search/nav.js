// The parts of the global search box that are decisions rather than DOM: which
// result a key moves to, and what a keypress means. Kept apart from the wiring
// so they can be run under node without a page.

// Every hit across the groups, in the order they are drawn, so one index walks
// down through the groups the way the eye does.
export function flatten(groups) {
  return (groups || []).flatMap((group) => group.results || []);
}

// Up/down through the hits, wrapping at both ends. -1 is "nothing picked":
// down from there lands on the first, up on the last.
export function move(index, count, delta) {
  if (count <= 0) return -1;
  if (index < 0) return delta > 0 ? 0 : count - 1;

  return (index + delta + count) % count;
}

// Enter opens the picked hit, or the first one when nothing has been picked -
// typing a name and pressing Enter should land on the best match.
export function target(hits, index) {
  if (!hits.length) return null;

  return (hits[index] || hits[0]).url;
}

// The box's own keys, or null for anything it leaves alone.
export function keyAction(event) {
  switch (event.key) {
    case "ArrowDown": return "down";
    case "ArrowUp":   return "up";
    case "Enter":     return "open";
    case "Escape":    return "close";
    default:          return null;
  }
}

// Cmd/Ctrl+K anywhere, or "/" when the person isn't already typing somewhere.
export function opensOverlay(event, typing) {
  if ((event.metaKey || event.ctrlKey) && String(event.key).toLowerCase() === "k") return true;

  return event.key === "/" && !typing && !event.metaKey && !event.ctrlKey && !event.altKey;
}
