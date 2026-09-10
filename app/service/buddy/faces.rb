module Buddy
  # Single source of truth for which expression faces exist, per theme.
  # Derived from the actual image files so the prompt vocabulary, the
  # validation gate, and the rendered set never drift as faces are added.
  module Faces
    module_function

    # Driven by connection / usage-cap state, not moods Buddy chooses.
    #
    # `sleeping_frown` was here too. Nothing ever set it — Buddy::SleepGuard
    # reaches for `:sleeping` for both the usage cap and an outage — so it was a
    # face only Byte had art for and nobody could ever see. Removed 2026-08-25.
    SYSTEM = %i[sleeping].freeze

    # Transitional-only: the face shown WHILE a reply is being generated.
    # It's the pet's "working on it" state, not a delivered expression — by
    # the time words land, the thinking is done. Never offered as a [[mood:]]
    # (Buddy would otherwise rest on it), but still renderable so the server
    # can set it during a turn.
    TRANSITIONAL = %i[thinking].freeze

    def dir(theme)
      Rails.root.join("app/assets/images/buddy/#{theme.to_s.presence || 'byte'}")
    end

    # Every face that exists for a theme (png or svg), as symbols.
    def all(theme)
      Dir[dir(theme).join("face_*.{png,svg}")]
        .map { |p| File.basename(p, ".*").delete_prefix("face_").to_sym }
        .uniq
    end

    # Faces Buddy may pick as a [[mood:]] — excludes the system faces and
    # the transitional "thinking" face (which is server-driven, never a
    # delivered mood).
    def selectable(theme)
      (all(theme) - SYSTEM - TRANSITIONAL).sort
    end

    # A face Buddy is actually allowed to deliver as its mood. Tighter than
    # `valid?` — blocks system/transitional faces even if the model emits one.
    def selectable?(theme, expression)
      selectable(theme).include?(expression.to_s.to_sym)
    end

    # The resting face. Where the pet sits when nothing has moved it, and where
    # it returns after a lull (see BuddyExpressionResetWorker).
    def default
      :neutral
    end

    def valid?(theme, expression)
      all(theme).include?(expression.to_s.to_sym)
    end

    # What each face IS, written from the art. Lived in Buddy::Personality as
    # FACE_HINTS while the model picked its own face and needed the vocabulary
    # in front of it; it doesn't any more, and 4kb of face descriptions in every
    # prompt went with the rest of that.
    #
    # Kept, and kept HERE, because it is the prose half of PROFILES below - the
    # sentence and the four numbers describe the same face and drift apart the
    # moment they live in different files. This is what a profile is written
    # from, and what the next person reads to decide whether one is wrong.
    HINTS = {
      # shared
      neutral:       "calm little smile, unbothered — your resting default for flat, nothing-happening moments",
      happy:         "bright open-eyed smile, a wave, sparkles — cheerful, upbeat, lightening the mood, a small win",
      sad:           "downcast eyes and a frown — deflated, tender, sitting with something heavy",
      crying:        "teary eyes, quivering frown — moved, upset, right there with them in a hard moment",
      surprised:     "wide round eyes, open mouth — startled, caught off guard, 'oh!'",
      thinking:      "chin held, thought bubble up — pondering, a little uncertain, working a problem out with them",
      loving:        "hearts about it — adoring, smitten, full of affection",
      # Byte extras
      neutral_blush: "that same resting smile with a bashful blush — shy, flattered, quietly touched",
      uwu:           "eyes-closed open-mouth laugh — gleeful, tickled, delighted, sassy, cute, playful",
      nerd:          "glasses on, book out — studious, clever, just figured something out or nailed the answer, or encouraging something nerdy",
      annoyed:       "furrowed brow, small scowl — mildly grumpy / exasperated (playful, never at the person)",
      confused:      "small frown, wide uncertain eyes, a question mark — puzzled, thrown, didn't expect that, can't work out what happened",
      focused:       "hard narrowed eyes, set frown — locked onto something difficult; it reads STERN, so never for a light moment or a small favour",
      playful:       "one-eyed wink and a grin — teasing, cheeky, being a bit of a menace about it",
      # Moss extras
      content:       "serene eyes-closed smile — settled, satisfied, at peace",
      grin:          "big beaming grin — laughing, thrilled, delighted",
      star:          "star-shaped eyes — starstruck, dazzled, over-the-moon excited",
      wink:          "one-eyed wink and a smirk — playful, cheeky, teasing",
      shocked:       "wide staring eyes — stunned, taken aback, alarmed",
      frustrated:    "scrunched >< eyes and a gritted grimace — fed up, exasperated, at wit's end",
      angry:         "sharp furrowed brows, hard frown — cross, mad, indignant",
      queasy:        "droopy half-lids, frown, big sigh — overwhelmed, stressed, uneasy, 'bleh', exasperated",
      dizzy:         "spiral eyes, wobbly mouth — dazed, spun-out, overwhelmed, frazzled, squirrel-brained, too much at once",
      unamused:      "a dead-straight line for a mouth — deadpan, skeptical, distinctly unimpressed",
      # Moss + Glimmer
      dismayed:      "worried brows, mouth open, hands up — caught out, put out, 'ah, that didn't work' (about the thing, never about them)",
      # Suki extras
      cheery:        "eyes-closed open-mouth beam, wing to a blushing cheek — warm, delighted, tickled, quietly pleased",
      offering:      "holding up a little tub of food — bringing you something, being helpful, the sugar-beak move",
      excited:       "wings thrown wide with sparkles — thrilled, over-the-moon, celebrating a win",
    }.freeze

    # ---- where each face sits, so one can be CHOSEN rather than rolled ------
    #
    # Four axes, each 0..1, the same four Buddy::Sentiment reads off a
    # conversation. A face is a point in that space and picking one is a
    # nearest-neighbour lookup, which is the whole mechanism.
    #
    #   warmth — how good this moment is (0 bleak, 0.5 flat, 1 delighted)
    #   play   — how light it is (0 dead earnest, 1 mucking about)
    #   weight — how much is at stake (0 trivial, 1 really matters to them)
    #   strain — how much friction is in the room (0 none, 1 fed up)
    #
    # `weight` is the axis that was missing entirely, and it is why prod 5759
    # could put the glasses on over a rejection: `nerd` and `sad` are miles
    # apart on it and were indistinguishable to a table that only knew
    # "pleased" from "not pleased".
    #
    # Written from the art and from HINTS above, so the two describe the same
    # face. Every selectable face in every theme needs a row in BOTH - the specs
    # fail on a missing one rather than letting it quietly become unreachable.
    PROFILES = {
      angry:         { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95 },
      annoyed:       { warmth: 0.25, play: 0.30, weight: 0.35, strain: 0.80 },
      cheery:        { warmth: 0.90, play: 0.55, weight: 0.15, strain: 0.05 },
      confused:      { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45 },
      content:       { warmth: 0.80, play: 0.15, weight: 0.25, strain: 0.05 },
      crying:        { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.30 },
      dismayed:      { warmth: 0.25, play: 0.20, weight: 0.50, strain: 0.50 },
      dizzy:         { warmth: 0.40, play: 0.55, weight: 0.40, strain: 0.60 },
      excited:       { warmth: 0.95, play: 0.65, weight: 0.25, strain: 0.05 },
      focused:       { warmth: 0.45, play: 0.05, weight: 0.85, strain: 0.35 },
      frustrated:    { warmth: 0.20, play: 0.15, weight: 0.55, strain: 0.90 },
      grin:          { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05 },
      happy:         { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05 },
      loving:        { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05 },
      # Pleased AND a bit clever, and — the part that matters — LIGHT. It is
      # reachable again precisely because `weight` can now keep it away from a
      # moment that isn't.
      nerd:          { warmth: 0.70, play: 0.50, weight: 0.35, strain: 0.05 },
      neutral:       { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15 },
      neutral_blush: { warmth: 0.75, play: 0.30, weight: 0.30, strain: 0.05 },
      offering:      { warmth: 0.80, play: 0.30, weight: 0.25, strain: 0.10 },
      playful:       { warmth: 0.80, play: 0.95, weight: 0.10, strain: 0.10 },
      queasy:        { warmth: 0.20, play: 0.10, weight: 0.60, strain: 0.60 },
      sad:           { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25 },
      shocked:       { warmth: 0.30, play: 0.20, weight: 0.75, strain: 0.35 },
      star:          { warmth: 0.95, play: 0.60, weight: 0.35, strain: 0.05 },
      surprised:     { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25 },
      unamused:      { warmth: 0.35, play: 0.35, weight: 0.30, strain: 0.55 },
      uwu:           { warmth: 0.90, play: 0.90, weight: 0.10, strain: 0.05 },
      wink:          { warmth: 0.80, play: 0.90, weight: 0.10, strain: 0.10 },
    }.freeze

    AXES = %i[warmth play weight strain].freeze

    # `play` counts for less because it's the axis a reading is least sure
    # about - a person can be light about something heavy - and letting it pull
    # as hard as the others turned an earnest thank-you into a wink.
    AXIS_WEIGHTS = { warmth: 1.0, play: 0.7, weight: 1.0, strain: 0.9 }.freeze

    def profile(face)
      PROFILES[face.to_s.to_sym]
    end

    # The face this theme has that sits closest to a reading. Nil when the theme
    # somehow has nothing profiled, which is a bug the spec catches rather than
    # something to paper over at runtime.
    #
    # `skip` is how "an action never leaves the pet resting" is said, and it is
    # said HERE rather than by weighting the reading, because it isn't a claim
    # about the moment. A genuinely flat moment IS flat; what's wrong is a pet
    # that just did something for someone and shows nothing for it. Nudging
    # warmth up until `neutral` stopped winning would have been the same
    # sentence told as a lie about the room, and strong enough to matter it
    # also dragged a rejection off `sad`.
    def nearest(theme, reading, skip: [])
      away = Array(skip).map(&:to_sym)
      candidates = (selectable(theme) - away).filter_map { |face|
        point = PROFILES[face]
        [face, distance(point, reading)] if point
      }
      candidates.min_by(&:last)&.first
    end

    def distance(point, reading)
      AXES.sum { |axis|
        delta = point[axis].to_f - reading[axis].to_f
        AXIS_WEIGHTS[axis] * delta * delta
      }
    end
  end
end
