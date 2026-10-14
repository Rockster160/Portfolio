module Buddy
  module Companions
    # Tiko — the spirit fox. Foxfire and quiet wonder; holes where it has no art
    # (no sad / crying), which the picker simply falls back around.
    class Tiko < Buddy::Companion
      identity(
        key:         :tiko,
        name:        "Tiko",
        description: "the spirit fox",
        color:       "#101D38",
        tone:        :chelsea,
      )
      summary "A serene spirit fox — watchful and gentle, with a flicker of playful foxfire."

      emotions(
        neutral:   { summary: "calm little smile, unbothered — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        happy:     { summary: "bright open-eyed smile — cheerful, upbeat, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 } },
        grin:      { summary: "big beaming grin — laughing, thrilled, delighted", axes: { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.18 } },
        loving:    { summary: "hearts about it — adoring, smitten, full of affection", axes: { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 } },
        wink:      { summary: "one-eyed wink and a smirk — playful, cheeky, teasing", axes: { warmth: 0.80, play: 0.90, weight: 0.10, strain: 0.10, reach: 0.18 } },
        playful:   { summary: "tails swishing, a grin — teasing, cheeky, being a bit of a menace about it", axes: { warmth: 0.80, play: 0.95, weight: 0.10, strain: 0.10, reach: 0.18 } },
        cool:      { summary: "shades on, a little peace sign — confident, unbothered, got it handled; swagger about the WIN", axes: { warmth: 0.70, play: 0.65, weight: 0.25, strain: 0.05, reach: 0.18 } },
        cozy:      { summary: "curled up warm, foxfire low — cosy, settled, content", axes: { warmth: 0.82, play: 0.20, weight: 0.20, strain: 0.05, reach: 0.22 } },
        content:   { summary: "eyes-closed smile, tails folded — settled and satisfied", axes: { warmth: 0.80, play: 0.15, weight: 0.25, strain: 0.05, reach: 0.25 } },
        nerd:      { summary: "glasses on, a scroll out — studious, clever, just figured something out", axes: { warmth: 0.70, play: 0.50, weight: 0.35, strain: 0.05, reach: 0.25 } },
        cheering:  { summary: "eyes shut, paws thrown up, foxfire flaring — celebrating, a win worth making a noise about", axes: { warmth: 0.95, play: 0.35, weight: 0.70, strain: 0.05, reach: 0.14 } },
        eager:     { summary: "big shining eyes, ears perked — keen, leaning in and waiting for it", axes: { warmth: 0.65, play: 0.30, weight: 0.55, strain: 0.20, reach: 0.18 } },
        peeking:   { summary: "just the eyes and ears over an edge — sneaking a look, checking in, shy curiosity", axes: { warmth: 0.55, play: 0.55, weight: 0.20, strain: 0.25, reach: 0.20 } },
        surprised: { summary: "wide round eyes, ears up — startled, caught off guard, 'oh!'", axes: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 } },
        confused:  { summary: "small frown, wide uncertain eyes, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 } },
        angry:     { summary: "sharp furrowed brows, hard frown, foxfire sharp — cross, mad, indignant", axes: { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95, reach: 0.14 } },
      )
    end
  end
end
