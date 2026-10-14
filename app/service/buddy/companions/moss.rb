module Buddy
  module Companions
    # Moss — the round mossy sprite with a little sprout.
    class Moss < Buddy::Companion
      identity(
        key:         :moss,
        name:        "Moss",
        description: "the mossy forest sprite",
        color:       "#14231A",
        tone:        :chelsea,
      )
      summary "A calm, grounded forest sprite — warm, unhurried, quietly encouraging."

      emotions(
        neutral:    { summary: "calm little smile, unbothered — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        happy:      { summary: "bright open-eyed smile — cheerful, upbeat, lightening the mood, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 } },
        grin:       { summary: "big beaming grin — laughing, thrilled, delighted", axes: { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.18 } },
        star:       { summary: "star-shaped eyes — starstruck, dazzled, over-the-moon excited", axes: { warmth: 0.95, play: 0.60, weight: 0.35, strain: 0.05, reach: 0.15 } },
        loving:     { summary: "hearts about it — adoring, smitten, full of affection", axes: { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 } },
        wink:       { summary: "one-eyed wink and a smirk — playful, cheeky, teasing", axes: { warmth: 0.80, play: 0.90, weight: 0.10, strain: 0.10, reach: 0.18 } },
        content:    { summary: "eyes-closed smile, a serene mossy ball at rest — settled and satisfied", axes: { warmth: 0.80, play: 0.15, weight: 0.25, strain: 0.05, reach: 0.25 } },
        surprised:  { summary: "wide round eyes, open mouth — startled, caught off guard, 'oh!'", axes: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 } },
        shocked:    { summary: "wide staring eyes — stunned, taken aback, alarmed", axes: { warmth: 0.30, play: 0.20, weight: 0.75, strain: 0.35, reach: 0.16 } },
        confused:   { summary: "small frown, wide uncertain eyes, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 } },
        focused:    { summary: "hard narrowed eyes, set frown — locked onto something difficult; reads STERN, never for a light moment", axes: { warmth: 0.45, play: 0.05, weight: 0.85, strain: 0.35, reach: 0.13 } },
        dismayed:   { summary: "worried brows, mouth open, hands up — caught out, 'ah, that didn't work' (about the thing, never them)", axes: { warmth: 0.25, play: 0.20, weight: 0.50, strain: 0.50, reach: 0.25 } },
        dizzy:      { summary: "spiral eyes, wobbly mouth — dazed, spun-out, overwhelmed, too much at once", axes: { warmth: 0.40, play: 0.55, weight: 0.40, strain: 0.60, reach: 0.15 } },
        queasy:     { summary: "droopy half-lids, frown, big sigh — overwhelmed, stressed, uneasy, 'bleh'", axes: { warmth: 0.20, play: 0.10, weight: 0.60, strain: 0.60, reach: 0.25 } },
        unamused:   { summary: "a dead-straight line for a mouth — deadpan, skeptical, distinctly unimpressed", axes: { warmth: 0.35, play: 0.35, weight: 0.30, strain: 0.55, reach: 0.25 } },
        frustrated: { summary: "scrunched >< eyes and a gritted grimace — fed up, exasperated, at wit's end", axes: { warmth: 0.20, play: 0.15, weight: 0.55, strain: 0.90, reach: 0.15 } },
        angry:      { summary: "sharp furrowed brows, hard frown — cross, mad, indignant", axes: { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95, reach: 0.14 } },
        sad:        { summary: "downcast eyes and a frown — deflated, tender, sitting with something heavy", axes: { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 } },
        crying:     { summary: "teary eyes, quivering frown — moved, upset, right there with them in a hard moment", axes: { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.30, reach: 0.08 } },
      )
    end
  end
end
