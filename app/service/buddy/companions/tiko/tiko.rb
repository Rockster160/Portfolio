module Buddy
  module Companions
    # Tiko — the spirit fox in a witch hat. Foxfire and quiet wonder; holes where it
    # has no art, which the picker simply falls back around.
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
        neutral:   { summary: "witch hat on, big round eyes, a calm little smile, foxfire floating by — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        happy:     { summary: "eyes curved shut over a big open laugh, a paw up, hearts floating by — cheerful, upbeat, a small win", axes: { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 } },
        excited:   { summary: "bright wide eyes, an open smile, a paw reaching out, a burst of '!' — delighted, keen, can't wait", axes: { warmth: 0.90, play: 0.55, weight: 0.25, strain: 0.05, reach: 0.15 } },
        cozy:      { summary: "eyes shut, a soft smile over a steaming mug of cocoa — cosy, settled in, taking a moment", axes: { warmth: 0.82, play: 0.20, weight: 0.20, strain: 0.05, reach: 0.22 } },
        cool:      { summary: "dark shades on, a little smile, a sparkle — confident, unbothered, got it handled; swagger about the WIN", axes: { warmth: 0.70, play: 0.65, weight: 0.25, strain: 0.05, reach: 0.18 } },
        peeking:   { summary: "lying low with its chin on its tail, big eyes peering over, a little '!' — sneaking a look, checking in, shy curiosity", axes: { warmth: 0.55, play: 0.55, weight: 0.20, strain: 0.25, reach: 0.20 } },
        playful:   { summary: "paw raised mid-spell, sparkles and a swirl of foxfire, an open grin — casting a little magic, cheeky, showing off", axes: { warmth: 0.80, play: 0.95, weight: 0.10, strain: 0.10, reach: 0.18 } },
        loving:    { summary: "eyes shut, cuddling a ball of foxfire under floating hearts — adoring, smitten, full of affection", axes: { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 } },
        nerd:      { summary: "big eyes over an open moon-marked spellbook — studious, reading up, working something out", axes: { warmth: 0.70, play: 0.50, weight: 0.35, strain: 0.05, reach: 0.25 } },
        focused:   { summary: "tapping at a laptop, eyes on the screen — heads-down, busy getting it done", axes: { warmth: 0.55, play: 0.15, weight: 0.60, strain: 0.15, reach: 0.13 } },
        surprised: { summary: "wide round eyes, mouth open, a burst of '!' — startled, caught off guard, 'oh!'", axes: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 } },
        confused:  { summary: "a pouty little mouth, a paw at its cheek, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 } },
        unamused:  { summary: "half-lidded eyes, a flat little mouth — deadpan, skeptical, distinctly unimpressed", axes: { warmth: 0.35, play: 0.35, weight: 0.30, strain: 0.55, reach: 0.25 } },
        sad:       { summary: "glossy eyes under worried brows, a small wobbly frown — deflated, tender, sitting with something heavy", axes: { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 } },
        crying:    { summary: "eyes squeezed shut, mouth open in a wail, tears streaming — upset, right there with them in a hard moment", axes: { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.30, reach: 0.08 } },
        angry:     { summary: "narrowed eyes under hard brows, a flat frown, an anger mark — cross, mad, indignant", axes: { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95, reach: 0.14 } },
      )
    end
  end
end
