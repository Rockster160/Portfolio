// How a chore is searched for by name, everywhere one is picked: the Chores
// page's search box and pickers, and a board's pin and credit-button pickers.
// A chore's name counts fully, each of its aliases for half; within a field a
// prefix beats an infix beats letters-in-order. 0 is no match.
//
// The Chores page script is an inline module, so it reads this off
// `window.ChoreSearch`; bundled code imports it.

function fuzzyMatch(needle, hay) {
  let i = 0;
  let j = 0;
  while (i < needle.length && j < hay.length) {
    if (needle[i] === hay[j]) i++;
    j++;
  }
  return i === needle.length;
}

export function score(needle, name, aliases) {
  if (!needle) return 1;
  const n = needle.toLowerCase();
  const fields = [
    { text: (name || "").toLowerCase(), weight: 1.0 },
    ...(aliases || []).map((a) => ({ text: String(a).toLowerCase(), weight: 0.5 })),
  ];
  let best = 0;
  for (const { text, weight } of fields) {
    if (!text) continue;
    const idx = text.indexOf(n);
    let local = 0;
    if (idx === 0) local = 1.0;
    else if (idx > 0) local = 0.7 - Math.min(idx, 10) * 0.02;
    else if (fuzzyMatch(n, text)) local = 0.3;
    else continue;
    best = Math.max(best, local * weight);
  }
  return best;
}

// The chores matching `query`, best first, ties by name.
export function searchChores(chores, query) {
  const q = String(query || "").trim();
  return (chores || [])
    .map((c) => ({ c, s: score(q, c.short_name || c.name, c.aliases || []) }))
    .filter((x) => x.s > 0)
    .sort((a, b) => b.s - a.s || String(a.c.name || "").localeCompare(String(b.c.name || "")))
    .map((x) => x.c);
}

if (typeof window !== "undefined") window.ChoreSearch = { score, searchChores };
