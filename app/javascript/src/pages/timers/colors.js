// Pre-generated palette for auto-coloring timers without an explicit
// color. Deterministic per timer id so the same timer keeps the same
// color across renders. Tuned to read clearly on the dark background.

const PALETTE = [
  "#388bfd", "#a371f7", "#db61a2", "#f0883e",
  "#e3b341", "#3fb950", "#34d0e0", "#ff7b72",
];

export function autoColor(timer) {
  if (timer.color) return timer.color;
  const idx = Math.abs((timer.id || 0) * 31) % PALETTE.length;
  return PALETTE[idx];
}

export const ALL_COLORS = PALETTE.slice();
