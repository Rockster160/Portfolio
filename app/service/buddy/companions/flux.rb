module Buddy
  module Companions
    # Flux — the little octopus. Water-and-spark flavour: swirls, bubbles, a cosy box.
    class Flux < Buddy::Companion
      identity(
        key:         :flux,
        name:        "Flux",
        description: "the little octopus",
        color:       "#0C1E3C",
        tone:        :chelsea,
      )
      summary "A curious deep-sea octopus — inky, clever, and easygoing under pressure."

      emotions(
        neutral:       { summary: "calm little smile, unbothered — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        neutral_blush: { summary: "that resting smile with a bashful blush — shy, flattered, quietly touched", axes: { warmth: 0.75, play: 0.30, weight: 0.30, strain: 0.05, reach: 0.25 } },
        happy:         { summary: "bright open-eyed smile, bubbles rising — cheerful, upbeat, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 } },
        grin:          { summary: "big beaming grin — laughing, thrilled, delighted", axes: { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.18 } },
        loving:        { summary: "hearts about it — adoring, smitten, full of affection", axes: { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 } },
        hugging:       { summary: "tentacles wrapped around a big heart — holding something dear, the quiet end of affection", axes: { warmth: 0.95, play: 0.15, weight: 0.80, strain: 0.05, reach: 0.12 } },
        content:       { summary: "eyes-closed smile, tucked into a cosy box — settled and satisfied", axes: { warmth: 0.80, play: 0.15, weight: 0.25, strain: 0.05, reach: 0.25 } },
        cool:          { summary: "shades on, a little peace sign — confident, unbothered, got it handled; swagger about the WIN", axes: { warmth: 0.70, play: 0.65, weight: 0.25, strain: 0.05, reach: 0.18 } },
        excited:       { summary: "tentacles flung wide with sparkles — thrilled, over-the-moon, celebrating a win", axes: { warmth: 0.95, play: 0.65, weight: 0.25, strain: 0.05, reach: 0.15 } },
        star:          { summary: "star-shaped eyes — starstruck, dazzled, over-the-moon excited", axes: { warmth: 0.95, play: 0.60, weight: 0.35, strain: 0.05, reach: 0.15 } },
        nerd:          { summary: "glasses on, a book out — studious, clever, just figured something out", axes: { warmth: 0.70, play: 0.50, weight: 0.35, strain: 0.05, reach: 0.25 } },
        playful:       { summary: "one-eyed wink and a grin — teasing, cheeky, being a bit of a menace about it", axes: { warmth: 0.80, play: 0.95, weight: 0.10, strain: 0.10, reach: 0.18 } },
        eager:         { summary: "big shining eyes, leaning in — perked up, keen, waiting for it", axes: { warmth: 0.65, play: 0.30, weight: 0.55, strain: 0.20, reach: 0.18 } },
        focused:       { summary: "hard narrowed eyes, set frown — locked onto something difficult; reads STERN, never for a light moment", axes: { warmth: 0.45, play: 0.05, weight: 0.85, strain: 0.35, reach: 0.13 } },
        surprised:     { summary: "wide round eyes, open mouth — startled, caught off guard, 'oh!'", axes: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 } },
        confused:      { summary: "small frown, wide uncertain eyes, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 } },
        dismayed:      { summary: "worried brows, mouth open, tentacles up — caught out, 'ah, that didn't work' (about the thing, never them)", axes: { warmth: 0.25, play: 0.20, weight: 0.50, strain: 0.50, reach: 0.25 } },
        hiding:        { summary: "curled up small, just the eyes out — hiding, wanting to disappear, overwhelmed in a cute way", axes: { warmth: 0.45, play: 0.60, weight: 0.30, strain: 0.60, reach: 0.18 } },
        angry:         { summary: "sharp furrowed brows, an inky glare — cross, mad, indignant", axes: { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95, reach: 0.14 } },
        sad:           { summary: "downcast eyes and a frown — deflated, tender, sitting with something heavy", axes: { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 } },
        crying:        { summary: "teary eyes, quivering frown — moved, upset, right there with them in a hard moment", axes: { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.30, reach: 0.08 } },
      )
    end
  end
end
