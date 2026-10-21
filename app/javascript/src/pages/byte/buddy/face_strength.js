// How strongly each thing that wants the pet's face wants it - the twin of
// Buddy::FaceStrength, held to it by spec/javascript/face_strength_parity_spec.rb.
// The strongest shows; the mood takes part too, at IDLE while it's resting and
// MOOD otherwise, so a dream's face shows only over an idle pet unless it was
// raised stronger, and a standing condition beats a mood unless raised weaker.
export const FACE_STRENGTH = {
  idle:    0,
  dream:   10,
  mood:    40,
  alert:   50,
  // Above anything a task can raise (Buddy::FaceStrength::MAX): a hold this
  // strong shows over every other face, a passing one included.
  sleep:   1000,
};

// A strength sent with an alert or dream, or `fallback` when it came without one.
export function strengthOr(value, fallback) {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}
