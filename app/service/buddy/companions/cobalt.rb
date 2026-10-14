module Buddy
  module Companions
    # Cobalt — the blue dragon. A little flame it breathes when fired up, gems, a
    # witch hat and shades.
    class Cobalt < Buddy::Companion
      identity(
        key:         :cobalt,
        name:        "Cobalt",
        description: "the blue dragon",
        color:       "#0D1640",
        tone:        :chelsea,
      )
      summary "A spirited blue dragon — confident and playful, with a little flame to show off."

      emotions(
        neutral:       { summary: "calm little smile, unbothered — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        neutral_blush: { summary: "that resting smile with a bashful blush — shy, flattered, quietly touched", axes: { warmth: 0.75, play: 0.30, weight: 0.30, strain: 0.05, reach: 0.25 } },
        happy:         { summary: "bright open-eyed smile — cheerful, upbeat, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 } },
        grin:          { summary: "big beaming grin — laughing, thrilled, delighted", axes: { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.18 } },
        loving:        { summary: "hearts about it — adoring, smitten, full of affection", axes: { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 } },
        hugging:       { summary: "wings wrapped around a big heart — holding something dear, the quiet end of affection", axes: { warmth: 0.95, play: 0.15, weight: 0.80, strain: 0.05, reach: 0.12 } },
        cheering:      { summary: "eyes shut, wings thrown up, flame flaring — celebrating, a win worth making a noise about", axes: { warmth: 0.95, play: 0.35, weight: 0.70, strain: 0.05, reach: 0.14 } },
        excited:       { summary: "wings flung wide with sparkles — thrilled, over-the-moon, celebrating a win", axes: { warmth: 0.95, play: 0.65, weight: 0.25, strain: 0.05, reach: 0.15 } },
        cool:          { summary: "shades on, a little peace sign — confident, unbothered, got it handled; swagger about the WIN", axes: { warmth: 0.70, play: 0.65, weight: 0.25, strain: 0.05, reach: 0.18 } },
        cozy:          { summary: "curled up warm, a wisp of smoke — cosy, settled, content", axes: { warmth: 0.82, play: 0.20, weight: 0.20, strain: 0.05, reach: 0.22 } },
        fired_up:      { summary: "breathing a little gust of flame — fired up, determined, showing off a bit", axes: { warmth: 0.60, play: 0.55, weight: 0.55, strain: 0.30, reach: 0.18 } },
        playful:       { summary: "one-eyed wink and a grin — teasing, cheeky, being a bit of a menace about it", axes: { warmth: 0.80, play: 0.95, weight: 0.10, strain: 0.10, reach: 0.18 } },
        nerd:          { summary: "glasses on, a tome out — studious, clever, just figured something out", axes: { warmth: 0.70, play: 0.50, weight: 0.35, strain: 0.05, reach: 0.25 } },
        offering:      { summary: "holding up a gem — bringing you something, being helpful", axes: { warmth: 0.80, play: 0.30, weight: 0.25, strain: 0.10, reach: 0.25 } },
        eager:         { summary: "big shining eyes, wings perked — keen, leaning in and waiting for it", axes: { warmth: 0.65, play: 0.30, weight: 0.55, strain: 0.20, reach: 0.18 } },
        peeking:       { summary: "just the eyes and horns over an edge — sneaking a look, checking in, shy curiosity", axes: { warmth: 0.55, play: 0.55, weight: 0.20, strain: 0.25, reach: 0.20 } },
        content:       { summary: "eyes-closed smile, tail curled round — settled and satisfied", axes: { warmth: 0.80, play: 0.15, weight: 0.25, strain: 0.05, reach: 0.25 } },
        focused:       { summary: "hard narrowed eyes, set frown — locked onto something difficult; reads STERN, never for a light moment", axes: { warmth: 0.45, play: 0.05, weight: 0.85, strain: 0.35, reach: 0.13 } },
        surprised:     { summary: "wide round eyes, open mouth — startled, caught off guard, 'oh!'", axes: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 } },
        confused:      { summary: "small frown, wide uncertain eyes, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 } },
        nervous:       { summary: "worried brows, wobbly smile, a sweat drop — nervous, sheepish, uh-oh, not sure this'll go well", axes: { warmth: 0.30, play: 0.25, weight: 0.60, strain: 0.60, reach: 0.18 } },
        annoyed:       { summary: "furrowed brow, small scowl — mildly grumpy / exasperated (playful, never at the person)", axes: { warmth: 0.25, play: 0.30, weight: 0.35, strain: 0.80, reach: 0.25 } },
        frustrated:    { summary: "scrunched >< eyes and a gritted grimace — fed up, exasperated, at wit's end", axes: { warmth: 0.20, play: 0.15, weight: 0.55, strain: 0.90, reach: 0.15 } },
        angry:         { summary: "sharp furrowed brows, flame sharp — cross, mad, indignant", axes: { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95, reach: 0.14 } },
        sad:           { summary: "downcast eyes and a frown — deflated, tender, sitting with something heavy", axes: { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 } },
        crying:        { summary: "teary eyes, quivering frown — moved, upset, right there with them in a hard moment", axes: { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.30, reach: 0.08 } },
      )
    end
  end
end
