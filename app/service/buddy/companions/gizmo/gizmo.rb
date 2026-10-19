module Buddy
  module Companions
    # Gizmo — the mimic chest. Tongue-out silliness, treasure spills, gems it
    # offers up.
    class Gizmo < Buddy::Companion
      identity(
        key:         :gizmo,
        name:        "Gizmo",
        description: "the mimic chest",
        color:       "#281B07",
        tone:        :chelsea,
      )
      summary "A goofy treasure-chest mimic — silly and greedy for fun, showing off its hoard."

      emotions(
        neutral:    { summary: "calm little grin, lid half-open — the resting default for flat, nothing-happening moments", axes: { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 } },
        grin:       { summary: "big beaming grin — laughing, thrilled, delighted", axes: { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.18 } },
        silly:      { summary: "tongue out, goofy grin — silly, cheeky, mucking about", axes: { warmth: 0.80, play: 0.95, weight: 0.08, strain: 0.10, reach: 0.18 } },
        playful:    { summary: "a cheeky grin, lid snapping — teasing, being a bit of a menace about it", axes: { warmth: 0.80, play: 0.95, weight: 0.10, strain: 0.10, reach: 0.18 } },
        cheering:   { summary: "lid thrown wide, coins flying — celebrating, a win worth making a noise about", axes: { warmth: 0.95, play: 0.35, weight: 0.70, strain: 0.05, reach: 0.14 } },
        excited:    { summary: "treasure spilling everywhere with sparkles — thrilled, over-the-moon, celebrating a win", axes: { warmth: 0.95, play: 0.65, weight: 0.25, strain: 0.05, reach: 0.15 } },
        star:       { summary: "star-shaped eyes over a pile of gems — starstruck, dazzled, over-the-moon excited", axes: { warmth: 0.95, play: 0.60, weight: 0.35, strain: 0.05, reach: 0.15 } },
        loving:     { summary: "hearts about it — adoring, smitten, full of affection", axes: { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 } },
        hugging:    { summary: "lid hugged around a big heart — holding something dear, the quiet end of affection", axes: { warmth: 0.95, play: 0.15, weight: 0.80, strain: 0.05, reach: 0.12 } },
        offering:   { summary: "holding up a gem — bringing you something, being helpful", axes: { warmth: 0.80, play: 0.30, weight: 0.25, strain: 0.10, reach: 0.25 } },
        content:    { summary: "eyes shut, lid resting, sat on its hoard — settled and satisfied", axes: { warmth: 0.80, play: 0.15, weight: 0.25, strain: 0.05, reach: 0.25 } },
        eager:      { summary: "big shining eyes, lid tilting in — keen, leaning in and waiting for it", axes: { warmth: 0.65, play: 0.30, weight: 0.55, strain: 0.20, reach: 0.18 } },
        peeking:    { summary: "lid cracked, just the eyes out — sneaking a look, checking in, shy curiosity", axes: { warmth: 0.55, play: 0.55, weight: 0.20, strain: 0.25, reach: 0.20 } },
        surprised:  { summary: "lid flung wide, wide eyes — startled, caught off guard, 'oh!'", axes: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 } },
        confused:   { summary: "lid cocked, a question mark — puzzled, thrown, can't work out what happened", axes: { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 } },
        frustrated: { summary: "scrunched >< eyes and a gritted grimace — fed up, exasperated, at wit's end", axes: { warmth: 0.20, play: 0.15, weight: 0.55, strain: 0.90, reach: 0.15 } },
        angry:      { summary: "sharp furrowed brows, lid snapping — cross, mad, indignant", axes: { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95, reach: 0.14 } },
      )
    end
  end
end
