// Dice spec parsing for the value grid and the virtual roller. Deliberately
// narrow - just "NdM" ("2d6", "1d20", "d6") - unlike pages/random/roll.js's
// full expression evaluator, because every value button needs an exact
// enumerable range rather than a one-off expression result.
const DICE_SPEC = /^(\d*)d(\d+)$/i;

export function parseDice(spec) {
  const match = DICE_SPEC.exec(String(spec || "").trim());
  if (!match) return null;
  const count = match[1] ? parseInt(match[1], 10) : 1;
  const faces = parseInt(match[2], 10);
  if (!count || !faces) return null;
  return { count, faces };
}

// Every possible sum for "count" dice of "faces" sides, ascending. A plain
// list (not a convolution) - the grid just needs the range, not the odds.
export function valuesFor(spec) {
  const dice = parseDice(spec);
  if (!dice) return [];
  const min = dice.count;
  const max = dice.count * dice.faces;
  const out = [];
  for (let v = min; v <= max; v++) out.push(v);
  return out;
}

// Above this many buttons the grid gives way to a keypad (plan: ~24 faces).
export const MAX_GRID_VALUES = 24;

// crypto.getRandomValues, not Math.random (roll.js's Dice.rand was fixed the
// same way). Returns { faces: [3, 4], total: 7 }.
export function rollDice(spec) {
  const dice = parseDice(spec) || { count: 1, faces: 6 };
  const buf = new Uint32Array(dice.count);
  crypto.getRandomValues(buf);
  const faces = Array.from(buf, (n) => (n % dice.faces) + 1);
  return { faces, total: faces.reduce((a, b) => a + b, 0) };
}

export function expectedFrequencyWeight(spec, value) {
  const dice = parseDice(spec);
  if (!dice) return 1;
  const { count, faces } = dice;
  const mid = (count * (faces + 1)) / 2;
  const span = (count * (faces - 1)) / 2 || 1;
  return 1 - (Math.abs(value - mid) / span) * 0.6;
}
