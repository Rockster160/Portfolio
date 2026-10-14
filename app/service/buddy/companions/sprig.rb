module Buddy
  module Companions
    # Sprig — the nature dragon. Leaf-breath, blossoms, a bird friend; holes are
    # fine, the picker falls back around them.
    class Sprig < Buddy::Companion
      identity(
        key:         :sprig,
        name:        "Sprig",
        description: "the nature dragon",
        color:       "#0F1E0D",
        tone:        :chelsea,
      )
      summary "A gentle little nature dragon — sprouting, nurturing, happiest tending to things."

      emotions(
        neutral:       { summary: "calm little smile, unbothered — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        neutral_blush: { summary: "that resting smile with a bashful blush — shy, flattered, quietly touched", axes: { warmth: 0.75, play: 0.30, weight: 0.30, strain: 0.05, reach: 0.25 } },
        happy:         { summary: "bright open-eyed smile, a blossom or two — cheerful, upbeat, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 } },
        grin:          { summary: "big beaming grin — laughing, thrilled, delighted", axes: { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.18 } },
        cheery:        { summary: "eyes-closed open-mouth beam — warm, delighted, tickled, quietly pleased", axes: { warmth: 0.90, play: 0.55, weight: 0.15, strain: 0.05, reach: 0.25 } },
        cheering:      { summary: "eyes shut, wings thrown up, leaves swirling — celebrating, a win worth making a noise about", axes: { warmth: 0.95, play: 0.35, weight: 0.70, strain: 0.05, reach: 0.14 } },
        loving:        { summary: "hearts about it — adoring, smitten, full of affection", axes: { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 } },
        hugging:       { summary: "wings wrapped around a big heart — holding something dear, the quiet end of affection", axes: { warmth: 0.95, play: 0.15, weight: 0.80, strain: 0.05, reach: 0.12 } },
        caring:        { summary: "soft smile, a little heart in a speech bubble — saying something kind; warmth offered rather than felt", axes: { warmth: 0.85, play: 0.15, weight: 0.35, strain: 0.05, reach: 0.18 } },
        content:       { summary: "eyes-closed smile, a bird friend perched close — settled and satisfied", axes: { warmth: 0.80, play: 0.15, weight: 0.25, strain: 0.05, reach: 0.25 } },
        fired_up:      { summary: "breathing a little gust of leaves — fired up, determined, showing off a bit", axes: { warmth: 0.60, play: 0.55, weight: 0.55, strain: 0.30, reach: 0.18 } },
        eager:         { summary: "big shining eyes, leaning in — keen, waiting for it", axes: { warmth: 0.65, play: 0.30, weight: 0.55, strain: 0.20, reach: 0.18 } },
        peeking:       { summary: "just the eyes over a leaf — sneaking a look, checking in, shy curiosity", axes: { warmth: 0.55, play: 0.55, weight: 0.20, strain: 0.25, reach: 0.20 } },
        confused:      { summary: "small frown, wide uncertain eyes, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 } },
        annoyed:       { summary: "furrowed brow, small scowl — mildly grumpy / exasperated (playful, never at the person)", axes: { warmth: 0.25, play: 0.30, weight: 0.35, strain: 0.80, reach: 0.25 } },
      )
    end
  end
end
