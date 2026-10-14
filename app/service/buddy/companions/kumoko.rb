module Buddy
  module Companions
    # Kumoko — the fuzzy little spider. Her own voice (self-tsukkomi).
    class Kumoko < Buddy::Companion
      identity(
        key:         :kumoko,
        name:        "Kumoko",
        description: "the fuzzy spider",
        color:       "#22140F",
        tone:        :kumoko,
      )
      summary "A plucky, motor-mouthed spider — excitable, dramatic, forever narrating herself."

      emotions(
        neutral:   { summary: "calm little smile, unbothered — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        happy:     { summary: "bright wide-eyed smile — cheerful, upbeat, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 } },
        loving:    { summary: "hearts about it — adoring, smitten, full of affection", axes: { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 } },
        wink:      { summary: "one-eyed wink and a smirk — playful, cheeky, teasing", axes: { warmth: 0.80, play: 0.90, weight: 0.10, strain: 0.10, reach: 0.18 } },
        content:   { summary: "eyes-closed smile, legs tucked in — settled and satisfied", axes: { warmth: 0.80, play: 0.15, weight: 0.25, strain: 0.05, reach: 0.25 } },
        munching:  { summary: "big eyes peering over a leaf she's clutching to her mouth — nibbling, peckish, quietly pleased with a snack", axes: { warmth: 0.70, play: 0.65, weight: 0.05, strain: 0.10, reach: 0.18 } },
        cheering:  { summary: "eyes shut, legs thrown up — celebrating, a win worth making a noise about", axes: { warmth: 0.95, play: 0.35, weight: 0.70, strain: 0.05, reach: 0.14 } },
        star:      { summary: "sparkling eyes in a burst of sparkles — starstruck, dazzled, over-the-moon excited", axes: { warmth: 0.95, play: 0.60, weight: 0.35, strain: 0.05, reach: 0.15 } },
        eager:     { summary: "big shining eyes, leaning in — perked up, keen, waiting for it", axes: { warmth: 0.65, play: 0.30, weight: 0.55, strain: 0.20, reach: 0.18 } },
        bashful:   { summary: "eyes closed, cheeks blushing, small smile — bashful, flattered, embarrassed by something sincere", axes: { warmth: 0.75, play: 0.30, weight: 0.30, strain: 0.05, reach: 0.25 } },
        touched:   { summary: "glassy, teary eyes and a wobbly little smile — moved, grateful, about to cry in a good way", axes: { warmth: 0.80, play: 0.10, weight: 0.85, strain: 0.10, reach: 0.15 } },
        peeking:   { summary: "just her eyes and front legs over an edge — sneaking a look, checking in, shy curiosity", axes: { warmth: 0.55, play: 0.55, weight: 0.20, strain: 0.25, reach: 0.20 } },
        umbrella:  { summary: "a leaf held over her head like an umbrella — weathering it, got it covered, cheerful under something rough", axes: { warmth: 0.65, play: 0.50, weight: 0.45, strain: 0.45, reach: 0.20 } },
        surprised: { summary: "wide round eyes, legs splayed — startled, caught off guard, 'oh!'", axes: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 } },
        confused:  { summary: "small frown, wide uncertain eyes, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 } },
        nervous:   { summary: "worried brows, wobbly smile, a sweat drop — nervous, sheepish, uh-oh, not sure this'll go well", axes: { warmth: 0.30, play: 0.25, weight: 0.60, strain: 0.60, reach: 0.18 } },
        hiding:    { summary: "tucked under a leaf like a blanket, just the eyes out — hiding, wanting to disappear, overwhelmed in a cute way", axes: { warmth: 0.45, play: 0.60, weight: 0.30, strain: 0.60, reach: 0.18 } },
        angry:     { summary: "sharp furrowed brows, hard frown — cross, mad, indignant", axes: { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95, reach: 0.14 } },
        sad:       { summary: "downcast eyes and a frown — deflated, tender, sitting with something heavy", axes: { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 } },
      )
    end
  end
end
