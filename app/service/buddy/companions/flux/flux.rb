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
        neutral:       { summary: "calm little smile, eyes open — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        neutral_blush: { summary: "eyes-closed resting smile with a soft blush — shy, flattered, quietly touched", axes: { warmth: 0.75, play: 0.25, weight: 0.30, strain: 0.05, reach: 0.24 } },
        happy:         { summary: "bright open-eyed smile, bubbles rising — cheerful, upbeat, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.24 } },
        grin:          { summary: "eyes scrunched shut in a big open-mouthed laugh — thrilled, delighted, laughing out loud", axes: { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.18 } },
        excited:       { summary: "head-back laugh with energy marks flying — over-the-moon, buzzing, celebrating a win", axes: { warmth: 0.95, play: 0.72, weight: 0.25, strain: 0.08, reach: 0.16 } },
        playful:       { summary: "eyes shut, cheeky open grin, deep blush — teasing, giddy, being a bit of a menace about it", axes: { warmth: 0.85, play: 0.92, weight: 0.12, strain: 0.08, reach: 0.18 } },
        enchanted:     { summary: "wizard hat and a flick of the wand, big grin — showing off, pleased with itself, a playful bit of magic", axes: { warmth: 0.80, play: 0.80, weight: 0.22, strain: 0.05, reach: 0.16 } },
        eager:         { summary: "big shining eyes, open smile, leaning in — perked up, keen, can't wait for it", axes: { warmth: 0.75, play: 0.45, weight: 0.40, strain: 0.15, reach: 0.18 } },
        content:       { summary: "eyes-closed smile with little sparkles — settled, pleased, quietly satisfied", axes: { warmth: 0.80, play: 0.30, weight: 0.25, strain: 0.05, reach: 0.22 } },
        wonder:        { summary: "eyes closed, cradling a little glowing world — quiet wonder, awed and absorbed, holding something precious", axes: { warmth: 0.65, play: 0.25, weight: 0.45, strain: 0.05, reach: 0.17 } },
        loving:        { summary: "heart-shaped eyes and floating hearts — adoring, smitten, full of affection", axes: { warmth: 0.95, play: 0.35, weight: 0.55, strain: 0.05, reach: 0.18 } },
        hugging:       { summary: "tentacles wrapped around a big heart — holding something dear, the quiet end of affection", axes: { warmth: 0.95, play: 0.15, weight: 0.80, strain: 0.05, reach: 0.12 } },
        nerd:          { summary: "a book open in its tentacles, eyes on the page — studious, absorbed, clever", axes: { warmth: 0.65, play: 0.35, weight: 0.42, strain: 0.08, reach: 0.22 } },
        focused:       { summary: "heads-down at the laptop — on it, working the problem, absorbed but calm", axes: { warmth: 0.45, play: 0.12, weight: 0.65, strain: 0.15, reach: 0.18 } },
        surprised:     { summary: "wide round eyes, open mouth, energy marks — startled, caught off guard, 'oh!'", axes: { warmth: 0.50, play: 0.40, weight: 0.50, strain: 0.30, reach: 0.24 } },
        confused:      { summary: "small frown, wide uncertain eyes, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.24 } },
        bashful:       { summary: "huge teary eyes, deep blush, tentacles pulled up over its mouth — shy, overwhelmed, wanting to hide in a cute way", axes: { warmth: 0.60, play: 0.35, weight: 0.35, strain: 0.45, reach: 0.18 } },
        dismayed:      { summary: "worried eyes, mouth tight, tentacles up — caught out, 'ah, that didn't work' (about the thing, never them)", axes: { warmth: 0.30, play: 0.15, weight: 0.50, strain: 0.50, reach: 0.24 } },
        angry:         { summary: "furrowed brows, an inky glare, a cross little mark — cross, mad, indignant", axes: { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95, reach: 0.14 } },
        sad:           { summary: "downturned frown, eyes low — deflated, tender, sitting with something heavy", axes: { warmth: 0.15, play: 0.05, weight: 0.72, strain: 0.25, reach: 0.22 } },
        crying:        { summary: "eyes squeezed shut, wailing, water flying — moved, upset, right there with them in a hard moment", axes: { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.35, reach: 0.10 } },
      )
    end
  end
end
