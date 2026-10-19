module Buddy
  module Companions
    # Byte — the blue slime. The default companion, and the only one whose icon
    # files carry no `byte-` prefix (so chrome overrides those two paths). Its
    # `content` is a squashed sparkling blob rather than a serene ball, so that
    # face reads and weighs differently here than on the others.
    class Byte < Buddy::Companion
      identity(
        key:         :byte,
        name:        "Byte",
        description: "the blue slime",
        color:       "#0E1930",
        tone:        :rimuru,
        chrome:      {
          touch_icon: "byte_favicon/apple-touch-icon.png",
          favicon:    "byte_favicon/favicon-96x96.png",
        },
      )
      summary "A quick, chipper slime — upbeat and a bit cheeky, keen to get things done."
      alarm_face :uwu

      emotions(
        neutral:       { summary: "calm little smile, unbothered — your resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        neutral_blush: { summary: "that same resting smile with a bashful blush — shy, flattered, quietly touched", axes: { warmth: 0.75, play: 0.30, weight: 0.30, strain: 0.05, reach: 0.25 } },
        happy:         { summary: "bright open-eyed smile, a wave, sparkles — cheerful, upbeat, lightening the mood, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 } },
        uwu:           { summary: "eyes-closed open-mouth laugh — gleeful, tickled, delighted, sassy, cute, playful", axes: { warmth: 0.90, play: 0.90, weight: 0.10, strain: 0.05, reach: 0.18 } },
        loving:        { summary: "hearts about it — adoring, smitten, full of affection", axes: { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 } },
        content:       { summary: "squashed flat and sparkling, eyes shut — pleased and a bit melted about it", axes: { warmth: 0.90, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.20 } },
        caring:        { summary: "eyes closed, soft smile, a little heart in a speech bubble — saying something kind; warmth offered rather than felt", axes: { warmth: 0.85, play: 0.15, weight: 0.35, strain: 0.05, reach: 0.18 } },
        hugging:       { summary: "both arms wrapped around a big heart, hearts drifting up — holding something dear, the quiet end of affection", axes: { warmth: 0.95, play: 0.15, weight: 0.80, strain: 0.05, reach: 0.12 } },
        cheering:      { summary: "eyes shut, wide grin, BOTH arms thrown up, bursts either side — celebrating, a win worth making a noise about", axes: { warmth: 0.95, play: 0.35, weight: 0.70, strain: 0.05, reach: 0.14 } },
        thumbs_up:     { summary: "a wink and a thumbs up — on it, got it, that's sorted; pleased about the job rather than the person", axes: { warmth: 0.80, play: 0.55, weight: 0.30, strain: 0.05, reach: 0.25 } },
        eager:         { summary: "big shining eyes, small pleased smile, marks off to one side — perked up, keen, leaning in and waiting for it", axes: { warmth: 0.65, play: 0.30, weight: 0.55, strain: 0.20, reach: 0.18 } },
        nerd:          { summary: "glasses on, book out — studious, clever, just figured something out, or encouraging something nerdy", axes: { warmth: 0.70, play: 0.50, weight: 0.35, strain: 0.05, reach: 0.25 } },
        playful:       { summary: "one-eyed wink and a grin — teasing, cheeky, being a bit of a menace about it", axes: { warmth: 0.80, play: 0.95, weight: 0.10, strain: 0.10, reach: 0.18 } },
        focused:       { summary: "hard narrowed eyes, set frown — locked onto something difficult; reads STERN, never for a light moment", axes: { warmth: 0.45, play: 0.05, weight: 0.85, strain: 0.35, reach: 0.13 } },
        confused:      { summary: "small frown, wide uncertain eyes, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 } },
        surprised:     { summary: "wide round eyes, open mouth — startled, caught off guard, 'oh!'", axes: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 } },
        annoyed:       { summary: "furrowed brow, small scowl — mildly grumpy / exasperated (playful, never at the person)", axes: { warmth: 0.25, play: 0.30, weight: 0.35, strain: 0.80, reach: 0.25 } },
        unamused:      { summary: "a dead-straight line for a mouth — deadpan, skeptical, distinctly unimpressed", axes: { warmth: 0.35, play: 0.35, weight: 0.30, strain: 0.55, reach: 0.25 } },
        sad:           { summary: "downcast eyes and a frown — deflated, tender, sitting with something heavy", axes: { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 } },
        crying:        { summary: "teary eyes, quivering frown — moved, upset, right there with them in a hard moment", axes: { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.30, reach: 0.08 } },
      )
    end
  end
end
