// Default player palette - distinct from each other in both light and dark
// mode - plus the hex helpers the colour sheet needs (normalize/validate a
// typed hex, and pick readable chip text by WCAG luminance). Any hex is
// allowed once typed in, so nothing here assumes a colour is readable;
// `textColorFor` is what makes a pale yellow or a near-black player still
// read on their own chip.

export const DEFAULT_COLORS = [
  "#e5484d", "#3fb950", "#388bfd", "#f0883e",
  "#a371f7", "#db61a2", "#e3b341", "#34d0e0",
  "#f47067", "#7ee787",
];

// "#d6609a", "d6609a", "#d6a" (3-digit shorthand) all normalize to a
// 6-digit lowercase hex. Returns null for anything else.
export function normalizeHex(raw) {
  const s = String(raw || "").trim().replace(/^#/, "").toLowerCase();
  if (/^[0-9a-f]{6}$/.test(s)) return `#${s}`;
  if (/^[0-9a-f]{3}$/.test(s)) return `#${s.split("").map((c) => c + c).join("")}`;
  return null;
}

export function isValidHex(raw) {
  return normalizeHex(raw) !== null;
}

// Relative luminance (WCAG) -> black or white text, whichever contrasts
// more, so the chip stays legible no matter how pale or dark the colour is.
export function textColorFor(hex) {
  const normalized = normalizeHex(hex) || "#888888";
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(normalized.slice(i, i + 2), 16) / 255);
  const lin = [r, g, b].map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  const luminance = (0.2126 * lin[0]) + (0.7152 * lin[1]) + (0.0722 * lin[2]);
  return luminance > 0.45 ? "#0d1117" : "#ffffff";
}

// First default colour nobody at THIS table is already using.
export function nextFreeColor(takenHexes) {
  const taken = new Set((takenHexes || []).map((h) => normalizeHex(h)));
  const free = DEFAULT_COLORS.find((c) => !taken.has(c));
  return free || DEFAULT_COLORS[Math.floor(Math.random() * DEFAULT_COLORS.length)];
}
