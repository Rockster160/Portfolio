module Buddy
  module Companions
    # Bloom — the nature dragon. Leaf-breath, blossoms, a bird friend; holes are
    # fine, the picker falls back around them.
    class Bloom < Buddy::Companion
      identity(
        key:         :bloom,
        name:        "Bloom",
        description: "the nature dragon",
        color:       "#0F1E0D",
        tone:        :chelsea,
      )
      summary "A gentle little nature dragon — sprouting, nurturing, happiest tending to things."

      emotions(
        neutral:       { summary: "calm little smile, a blossom tucked in — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        neutral_blush: { summary: "that resting smile with a bashful blush — shy, flattered, quietly touched", axes: { warmth: 0.75, play: 0.25, weight: 0.30, strain: 0.05, reach: 0.24 } },
        happy:         { summary: "bright open-eyed smile, a blossom or two — cheerful, upbeat, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.24 } },
        cheery:        { summary: "eyes-closed open-mouthed beam — warm, delighted, tickled, quietly pleased", axes: { warmth: 0.88, play: 0.50, weight: 0.18, strain: 0.05, reach: 0.22 } },
        grin:          { summary: "eyes scrunched shut in a big open laugh, sparkles — thrilled, delighted, laughing out loud", axes: { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.18 } },
        cheering:      { summary: "eyes shut, an arm thrown up, leaves flying — celebrating, a win worth making a noise about", axes: { warmth: 0.95, play: 0.55, weight: 0.45, strain: 0.08, reach: 0.15 } },
        playful:       { summary: "a one-eyed wink and a grin — teasing, cheeky, being a bit of a menace about it", axes: { warmth: 0.85, play: 0.92, weight: 0.12, strain: 0.08, reach: 0.18 } },
        pounce:        { summary: "crouched low, tail up, open-mouthed grin — about to spring, can't keep still, game on", axes: { warmth: 0.75, play: 0.85, weight: 0.40, strain: 0.20, reach: 0.17 } },
        enchanted:     { summary: "wizard hat and a glowing staff, big grin — showing off, pleased with itself, a playful bit of magic", axes: { warmth: 0.80, play: 0.80, weight: 0.22, strain: 0.05, reach: 0.16 } },
        eager:         { summary: "big shining eyes, leaning in — perked up, keen, can't wait for it", axes: { warmth: 0.70, play: 0.40, weight: 0.45, strain: 0.18, reach: 0.18 } },
        content:       { summary: "eyes-closed soft smile — settled, pleased, quietly satisfied", axes: { warmth: 0.80, play: 0.20, weight: 0.25, strain: 0.05, reach: 0.22 } },
        blooming:      { summary: "eyes closed, leaves and sparkles swirling up — in its element, tending something, serene and flourishing", axes: { warmth: 0.75, play: 0.30, weight: 0.45, strain: 0.05, reach: 0.17 } },
        loving:        { summary: "curled up with a heart, eyes closed — adoring, smitten, full of affection", axes: { warmth: 0.95, play: 0.35, weight: 0.55, strain: 0.05, reach: 0.18 } },
        hugging:       { summary: "arms wrapped around a big heart — holding something dear, the quiet end of affection", axes: { warmth: 0.95, play: 0.15, weight: 0.80, strain: 0.05, reach: 0.12 } },
        nerd:          { summary: "a book open in its paws, eyes on the page — studious, absorbed, clever", axes: { warmth: 0.65, play: 0.35, weight: 0.42, strain: 0.08, reach: 0.22 } },
        focused:       { summary: "heads-down at the laptop — on it, working the problem, absorbed but calm", axes: { warmth: 0.45, play: 0.12, weight: 0.65, strain: 0.15, reach: 0.18 } },
        confused:      { summary: "small frown, wide uncertain eyes, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.24 } },
        hiding:        { summary: "tucked under a big leaf, just the eyes peeking out — shy, overwhelmed, wanting to disappear for a bit (cutely)", axes: { warmth: 0.45, play: 0.45, weight: 0.35, strain: 0.55, reach: 0.18 } },
        nervous:       { summary: "worried eyes and a nervous sweat — anxious, unsure, bracing for it", axes: { warmth: 0.35, play: 0.20, weight: 0.45, strain: 0.60, reach: 0.20 } },
        annoyed:       { summary: "furrowed brow, a little cross mark — mildly grumpy / exasperated (playful, never at the person)", axes: { warmth: 0.25, play: 0.30, weight: 0.35, strain: 0.80, reach: 0.25 } },
        sad:           { summary: "downcast eyes welling up, a frown — deflated, tender, sitting with something heavy", axes: { warmth: 0.15, play: 0.05, weight: 0.72, strain: 0.25, reach: 0.22 } },
        crying:        { summary: "eyes squeezed shut, wailing, tears flying — moved, upset, right there with them in a hard moment", axes: { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.35, reach: 0.10 } },
      )
    end
  end
end
