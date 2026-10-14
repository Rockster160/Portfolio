module Buddy
  module Companions
    # Suki — the purple sunbird.
    class Suki < Buddy::Companion
      identity(
        key:         :suki,
        name:        "Suki",
        description: "the purple sunbird",
        color:       "#150A22",
        tone:        :eve,
      )
      summary "A bright, doting sunbird — sweet and attentive, always bringing you something."

      emotions(
        neutral:   { summary: "calm little smile, unbothered — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        happy:     { summary: "bright open-eyed smile — cheerful, upbeat, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 } },
        cheery:    { summary: "eyes-closed open-mouth beam, wing to a blushing cheek — warm, delighted, tickled, quietly pleased", axes: { warmth: 0.90, play: 0.55, weight: 0.15, strain: 0.05, reach: 0.25 } },
        excited:   { summary: "wings thrown wide with sparkles — thrilled, over-the-moon, celebrating a win", axes: { warmth: 0.95, play: 0.65, weight: 0.25, strain: 0.05, reach: 0.15 } },
        offering:  { summary: "holding up a little tub of food — bringing you something, being helpful, the sugar-beak move", axes: { warmth: 0.80, play: 0.30, weight: 0.25, strain: 0.10, reach: 0.25 } },
        loving:    { summary: "hearts about it — adoring, smitten, full of affection", axes: { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 } },
        surprised: { summary: "wide round eyes, open beak — startled, caught off guard, 'oh!'", axes: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 } },
        dizzy:     { summary: "spiral eyes, wobbly beak — dazed, spun-out, overwhelmed, too much at once", axes: { warmth: 0.40, play: 0.55, weight: 0.40, strain: 0.60, reach: 0.15 } },
        annoyed:   { summary: "furrowed brow, small scowl — mildly grumpy / exasperated (playful, never at the person)", axes: { warmth: 0.25, play: 0.30, weight: 0.35, strain: 0.80, reach: 0.25 } },
        focused:   { summary: "hard narrowed eyes, set frown — locked onto something difficult; reads STERN, never for a light moment", axes: { warmth: 0.45, play: 0.05, weight: 0.85, strain: 0.35, reach: 0.13 } },
        sad:       { summary: "downcast eyes and a drooping wing — deflated, tender, sitting with something heavy", axes: { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 } },
      )
    end
  end
end
