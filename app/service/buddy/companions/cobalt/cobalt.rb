module Buddy
  module Companions
    # Cobalt — the blue dragon. A little flame it breathes when fired up, a gem,
    # a spellbook, a laptop, a mug, a witch hat and shades.
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
        neutral:       { summary: "big round eyes, calm little smile — unbothered, the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        neutral_blush: { summary: "eyes squeezed shut, a tiny tongue-out smile and a blush — bashful, flattered, a quiet 'hehe'", axes: { warmth: 0.75, play: 0.50, weight: 0.20, strain: 0.05, reach: 0.25 } },
        happy:         { summary: "eyes curved shut over a soft closed smile, cheeks pink — gently pleased, a small win", axes: { warmth: 0.82, play: 0.35, weight: 0.20, strain: 0.05, reach: 0.25 } },
        content:       { summary: "wide still eyes, a small wavy mouth, sitting quietly — attentive, listening, taking it in", axes: { warmth: 0.50, play: 0.15, weight: 0.45, strain: 0.15, reach: 0.25 } },
        grin:          { summary: "a wink and a big open laugh, paw to its cheek — cheeky, teasing, in on the joke", axes: { warmth: 0.90, play: 0.90, weight: 0.10, strain: 0.05, reach: 0.18 } },
        playful:       { summary: "a starry witch hat pulled on, eyes bright — playing make-believe, a little bit of magic about it", axes: { warmth: 0.75, play: 0.85, weight: 0.25, strain: 0.05, reach: 0.18 } },
        excited:       { summary: "bright upturned eyes, open happy smile, cheeks flushed — delighted, a lovely surprise", axes: { warmth: 0.90, play: 0.55, weight: 0.25, strain: 0.05, reach: 0.15 } },
        loving:        { summary: "eyes shut, a huge open laugh, paws up by its face — overjoyed, squealing with delight", axes: { warmth: 0.95, play: 0.55, weight: 0.50, strain: 0.05, reach: 0.18 } },
        hugging:       { summary: "eyes shut, clutching a big red heart — holding something dear, the quiet end of affection", axes: { warmth: 0.95, play: 0.15, weight: 0.80, strain: 0.05, reach: 0.12 } },
        cheering:      { summary: "eyes shut, mouth wide open, a paw thrown up — celebrating, a win worth making a noise about", axes: { warmth: 0.95, play: 0.35, weight: 0.70, strain: 0.05, reach: 0.14 } },
        cool:          { summary: "dark shades on, a small easy smile — confident, unbothered, got it handled; swagger about the WIN", axes: { warmth: 0.70, play: 0.65, weight: 0.25, strain: 0.05, reach: 0.18 } },
        cozy:          { summary: "big eyes over a warm mug with a heart on it — cosy, settled in, taking a moment", axes: { warmth: 0.82, play: 0.20, weight: 0.20, strain: 0.05, reach: 0.22 } },
        fired_up:      { summary: "side-on, breathing a gust of flame — fired up, determined, showing off a bit", axes: { warmth: 0.60, play: 0.55, weight: 0.55, strain: 0.30, reach: 0.18 } },
        nerd:          { summary: "big eyes peering over an open spellbook — studious, reading up, working something out", axes: { warmth: 0.65, play: 0.40, weight: 0.40, strain: 0.05, reach: 0.25 } },
        focused:       { summary: "tapping at a laptop, eyes on the screen with a little smirk — heads-down, busy getting it done", axes: { warmth: 0.55, play: 0.15, weight: 0.60, strain: 0.15, reach: 0.13 } },
        offering:      { summary: "eyes shut happy, hugging a glowing blue gem — a treasure found, something precious brought back", axes: { warmth: 0.80, play: 0.30, weight: 0.35, strain: 0.05, reach: 0.25 } },
        eager:         { summary: "flat on its belly, eyes turned up, the tip of its tail flickering — lying in wait, keen for what's coming", axes: { warmth: 0.65, play: 0.30, weight: 0.55, strain: 0.20, reach: 0.18 } },
        peeking:       { summary: "sprawled low with its chin down, a small smile — lounging, idling, just hanging about", axes: { warmth: 0.60, play: 0.35, weight: 0.15, strain: 0.05, reach: 0.20 } },
        surprised:     { summary: "wide round eyes, mouth open in an 'oh!' — startled, caught off guard", axes: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 } },
        confused:      { summary: "big uncertain eyes, one brow up, a small wavy mouth — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 } },
        nervous:       { summary: "worried brows over glossy eyes, a wobbly mouth — nervous, sheepish, uh-oh, not sure this'll go well", axes: { warmth: 0.30, play: 0.25, weight: 0.60, strain: 0.60, reach: 0.18 } },
        annoyed:       { summary: "a narrow side-eye under a cross brow, small wavy scowl — grumpy, unimpressed (playful, never at the person)", axes: { warmth: 0.25, play: 0.30, weight: 0.35, strain: 0.80, reach: 0.25 } },
        frustrated:    { summary: "glaring under heavy brows, a flat scowl — fed up, had it with this", axes: { warmth: 0.20, play: 0.15, weight: 0.55, strain: 0.90, reach: 0.15 } },
        angry:         { summary: "eyes scrunched shut under hard brows, mouth clamped — fuming, boiling over", axes: { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95, reach: 0.14 } },
        sad:           { summary: "head low, worried brows, eyes shining — deflated, tender, sitting with something heavy", axes: { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 } },
        crying:        { summary: "brimming eyes with a tear spilling, a quivering frown — upset, right there with them in a hard moment", axes: { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.30, reach: 0.08 } },
      )
    end
  end
end
