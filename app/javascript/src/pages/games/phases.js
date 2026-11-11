// A game's phases: an ordered list of { name, color, steps, laps }. A phase
// with `laps` belongs to each player in turn - everyone works through its
// steps, `laps` times around the table - before the next phase. Wrapping
// past the last phase starts a new round, and the round's first player is
// picked by the game's `first_player` rule.
//
// Where a play stands lives in `phase_state`: { round, phase, step, lap,
// turn, lead }. `lead` is the round's first player; `turn` counts players
// done in the current lap of an each-player phase.

const EACH_PLAYER = /\((?:each|every)\s+player(?:\s*[x×]\s*(\d+))?\)/i;
const COLOR = /#([0-9a-fA-F]{3,8})\b/;

// Mirror of GameTemplate.parse_phases, for editing a play's phases mid-game.
export function parsePhases(text) {
  return String(text || "").split("\n").map((line) => line.trim()).filter(Boolean).map((line) => {
    const colon = line.indexOf(":");
    let head = colon === -1 ? line : line.slice(0, colon);
    const tail = colon === -1 ? "" : line.slice(colon + 1);
    let laps = null;
    let color = null;
    head = head.replace(EACH_PLAYER, (_, n) => { laps = Math.max(parseInt(n || "1", 10), 1); return " "; });
    head = head.replace(COLOR, (_, hex) => { color = `#${hex.toLowerCase()}`; return " "; });
    const phase = {
      name: head.replace(/\s+/g, " ").trim(),
      steps: tail.split(",").map((s) => s.replace(COLOR, " ").replace(/\s+/g, " ").trim()).filter(Boolean),
    };
    if (color) phase.color = color;
    if (laps) phase.laps = laps;
    return phase;
  }).filter((phase) => phase.name);
}

export function phasesText(phases) {
  return (phases || []).map((phase) => {
    const laps = phase.laps || 0;
    const head = [phase.name, phase.color, laps ? `(each player${laps > 1 ? ` x${laps}` : ""})` : null].filter(Boolean).join(" ");
    return phase.steps?.length ? `${head}: ${phase.steps.join(", ")}` : head;
  }).join("\n");
}

// A phase with no steps is still one press of Next.
export function stepCount(phase) {
  return Math.max(phase?.steps?.length || 0, 1);
}

// Missing or out-of-range pieces fall back to the top of the phase, so a
// play from before phases existed - or phases edited mid-game - still reads.
export function positionOf(play, phases) {
  const s = play.phase_state || {};
  const count = (play.players || []).length || 1;
  const phase = Number.isInteger(s.phase) && s.phase < phases.length ? s.phase : 0;
  const fresh = phase !== s.phase;
  const step = !fresh && s.step < stepCount(phases[phase]) ? s.step || 0 : 0;
  return {
    round: s.round || 1,
    phase,
    step,
    lap: !fresh && s.lap < (phases[phase]?.laps || 1) ? s.lap || 0 : 0,
    turn: !fresh && s.turn < count ? s.turn || 0 : 0,
    lead: Number.isInteger(s.lead) && s.lead < count ? s.lead : (play.current_player_index || 0),
  };
}

// The player the table is waiting on: each player in turn from the lead
// during an each-player phase, the lead otherwise.
export function playerIndexAt(phases, pos, playerCount) {
  if (!playerCount) return 0;
  const offset = phases[pos.phase]?.laps ? pos.turn : 0;
  return (pos.lead + offset) % playerCount;
}

// One press of Next: the next step, the next player's turn, the next lap,
// the next phase, or a new round with its lead picked by `nextLead`.
export function advance(phases, pos, playerCount, nextLead) {
  const phase = phases[pos.phase];
  const next = { ...pos };
  if (next.step + 1 < stepCount(phase)) { next.step += 1; return next; }
  next.step = 0;
  if (phase?.laps && playerCount) {
    next.turn += 1;
    if (next.turn < playerCount) return next;
    next.turn = 0;
    next.lap += 1;
    if (next.lap < phase.laps) return next;
    next.lap = 0;
  }
  next.phase += 1;
  if (next.phase < phases.length) return next;
  return { ...next, phase: 0, round: next.round + 1, lead: nextLead(pos.lead) };
}

// Ties go to whoever sits soonest after the current lead; the lead keeps it
// only when nobody else ties. `scoreOf(index)` is that player's total.
export function pickLead(rule, lead, playerCount, scoreOf) {
  if (!playerCount) return 0;
  if (rule === "rotate") return (lead + 1) % playerCount;
  if (rule !== "lowest_score" && rule !== "highest_score") return lead;
  const order = Array.from({ length: playerCount }, (_, i) => (lead + 1 + i) % playerCount);
  const better = rule === "lowest_score" ? (a, b) => a < b : (a, b) => a > b;
  return order.reduce((best, i) => (better(scoreOf(i), scoreOf(best)) ? i : best), order[0]);
}
