module Buddy
  module Companions
    # Mocha — the little coffee cup. A Moss-shaped set with a work / motivated
    # lean: keeps `cool` for a small swagger and `queasy` for the long-day sigh.
    class Mocha < Buddy::Companion
      identity(
        key:         :mocha,
        name:        "Mocha",
        description: "the little coffee cup",
        color:       "#241610",
        tone:        :chelsea,
      )
      summary "A cosy cup of coffee — warm and motivating, there to get you going and keep you steady."

      emotions(
        neutral:   { summary: "calm little smile, unbothered — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        happy:     { summary: "bright open-eyed smile — cheerful, upbeat, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 } },
        grin:      { summary: "big beaming grin — laughing, thrilled, delighted", axes: { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.18 } },
        cheering:  { summary: "eyes shut, wide grin, arms thrown up — celebrating, a win worth making a noise about", axes: { warmth: 0.95, play: 0.35, weight: 0.70, strain: 0.05, reach: 0.14 } },
        wink:      { summary: "one-eyed wink and a smirk — playful, cheeky, teasing", axes: { warmth: 0.80, play: 0.90, weight: 0.10, strain: 0.10, reach: 0.18 } },
        cool:      { summary: "sunglasses on, a little peace sign — confident, unbothered, got it handled; swagger about the WIN", axes: { warmth: 0.70, play: 0.65, weight: 0.25, strain: 0.05, reach: 0.18 } },
        hugging:   { summary: "arms wrapped around a big heart, hearts drifting up — holding something dear, the quiet end of affection", axes: { warmth: 0.95, play: 0.15, weight: 0.80, strain: 0.05, reach: 0.12 } },
        caring:    { summary: "soft smile, a little heart in a speech bubble — saying something kind; warmth offered rather than felt", axes: { warmth: 0.85, play: 0.15, weight: 0.35, strain: 0.05, reach: 0.18 } },
        loving:    { summary: "hearts about it — adoring, smitten, full of affection", axes: { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 } },
        content:   { summary: "eyes-closed smile, sipping a warm cup — settled and satisfied", axes: { warmth: 0.80, play: 0.15, weight: 0.25, strain: 0.05, reach: 0.25 } },
        offering:  { summary: "holding out a fresh cup — bringing you something, being helpful", axes: { warmth: 0.80, play: 0.30, weight: 0.25, strain: 0.10, reach: 0.25 } },
        eager:     { summary: "big shining eyes, leaning in — perked up, keen, waiting for it", axes: { warmth: 0.65, play: 0.30, weight: 0.55, strain: 0.20, reach: 0.18 } },
        surprised: { summary: "wide round eyes, open mouth — startled, caught off guard, 'oh!'", axes: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 } },
        confused:  { summary: "small frown, wide uncertain eyes, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 } },
        dizzy:     { summary: "spiral eyes, wobbly mouth — dazed, spun-out, overwhelmed, too much at once", axes: { warmth: 0.40, play: 0.55, weight: 0.40, strain: 0.60, reach: 0.15 } },
        queasy:    { summary: "droopy half-lids, big sigh — the end-of-a-long-one slump, overwhelmed, 'bleh'", axes: { warmth: 0.20, play: 0.10, weight: 0.60, strain: 0.60, reach: 0.25 } },
        angry:     { summary: "sharp furrowed brows, hard frown — cross, mad, indignant", axes: { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95, reach: 0.14 } },
        sad:       { summary: "downcast eyes and a frown — deflated, tender, sitting with something heavy", axes: { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 } },
        crying:    { summary: "teary eyes, quivering frown — moved, upset, right there with them in a hard moment", axes: { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.30, reach: 0.08 } },
      )
    end
  end
end
