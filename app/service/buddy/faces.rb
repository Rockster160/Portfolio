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
    # face only Byte had art for and nobody could ever see.
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
    # Kept, and kept HERE, because it is the prose half of INDEX below - the
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
      cheering:      "eyes squeezed shut, wide open grin, BOTH arms thrown up, bursts either side — celebrating, thrilled for them, a win worth making a noise about",
      thumbs_up:     "a wink and a thumbs up — on it, got it, that's sorted; pleased with itself in a way that is about the job rather than the person",
      hugging:       "eyes closed, both arms wrapped around a big heart, hearts drifting up — holding something dear, tender, the quiet end of affection",
      caring:        "eyes closed, soft smile, a little heart in a speech bubble — saying something kind; warmth offered rather than felt",
      eager:         "big shining wide-open eyes, small pleased smile, marks off to one side — perked up, keen, leaning in and waiting for it",
      # Moss extras
      # THREE drawings under one name, which is why INDEX is keyed by theme:
      # Moss's and Glimmer's are round and still, Byte's is squashed flat and
      # sparkling. The prose covers all of them; the numbers no longer have to.
      content:       "eyes-closed smile — settled and satisfied on Moss and Glimmer; on Byte, squashed flat and sparkling, pleased and a bit melted about it",
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

    # ---- the index: every face a pet HAS, with its own numbers -------------
    #
    # Keyed by THEME first and face second. The name is a label for whoever is
    # reading the file; it carries no meaning the art has to live up to, and
    # two pets drawn differently under one name get two rows.
    #
    # That was not true until now and it cost a face: Byte's `content` art
    # arrived three days after the table and reused the row written for Moss's,
    # which is a round mossy ball with its eyes closed - so a blob squashed
    # flat and sparkling inherited "settled, at peace" and became the pet's
    # answer to almost every errand.
    #
    # Four axes, each 0..1, the same four Buddy::Sentiment reads off a
    # conversation:
    #
    #   warmth — how good this moment is (0 bleak, 0.5 flat, 1 delighted)
    #   play   — how light it is (0 dead earnest, 1 mucking about)
    #   weight — how much is at stake (0 trivial, 1 really matters to them)
    #   strain — how much friction is in the room (0 none, 1 fed up)
    #
    # `weight` is the axis that was missing entirely, and without it the
    # glasses go on over a rejection: `nerd` and `sad` are miles apart on it
    # and were indistinguishable to a table that only knew "pleased" from
    # "not pleased".
    #
    # ## `reach` is the range, and it is what makes a match RELEVANT
    #
    # A row is a centre plus a reach, which together are a range per axis:
    # `warmth 0.85 reach 0.25` means this face answers readings from 0.60 to
    # 1.00 and nothing outside it. A reading has to land inside ALL FOUR to be
    # this face's business at all.
    #
    # Nearest-neighbour alone has no such notion - every face is a candidate
    # for every reading, and the loud ones win by default whenever the quiet
    # ones happen to be further away.
    #
    # **The reach is smaller the louder the face is**, and that is the whole
    # rule for setting one. `crying` at 0.08 answers grief and nothing else; an
    # unbounded lookup had it second-nearest to an ordinary rejection, at odds
    # that would have had the pet in tears over a job knock-back better than
    # one time in three. `focused` at 0.13 for the same reason, and it is on
    # record: "he's often using the focused/angry face for those which feels
    # inappropriate". `neutral` is widest at 0.32, because resting IS the broad
    # answer to a flat moment.
    #
    # Written from the art and from HINTS above, so the two describe the same
    # face. Every selectable face in every theme needs a row in BOTH - the
    # specs fail on a missing one rather than letting it quietly become
    # unreachable.
    INDEX = {
      byte:    {
        annoyed:       { warmth: 0.25, play: 0.30, weight: 0.35, strain: 0.80, reach: 0.25 },
        caring:        { warmth: 0.85, play: 0.15, weight: 0.35, strain: 0.05, reach: 0.18 },
        cheering:      { warmth: 0.95, play: 0.35, weight: 0.70, strain: 0.05, reach: 0.14 },
        confused:      { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 },
        content:       { warmth: 0.90, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.20 },
        crying:        { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.30, reach: 0.08 },
        eager:         { warmth: 0.65, play: 0.30, weight: 0.55, strain: 0.20, reach: 0.18 },
        focused:       { warmth: 0.45, play: 0.05, weight: 0.85, strain: 0.35, reach: 0.13 },
        happy:         { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 },
        hugging:       { warmth: 0.95, play: 0.15, weight: 0.80, strain: 0.05, reach: 0.12 },
        loving:        { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 },
        nerd:          { warmth: 0.70, play: 0.50, weight: 0.35, strain: 0.05, reach: 0.25 },
        neutral:       { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 },
        neutral_blush: { warmth: 0.75, play: 0.30, weight: 0.30, strain: 0.05, reach: 0.25 },
        playful:       { warmth: 0.80, play: 0.95, weight: 0.10, strain: 0.10, reach: 0.18 },
        sad:           { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 },
        surprised:     { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 },
        thumbs_up:     { warmth: 0.80, play: 0.55, weight: 0.30, strain: 0.05, reach: 0.25 },
        unamused:      { warmth: 0.35, play: 0.35, weight: 0.30, strain: 0.55, reach: 0.25 },
        uwu:           { warmth: 0.90, play: 0.90, weight: 0.10, strain: 0.05, reach: 0.18 },
      },
      moss:    {
        angry:      { warmth: 0.05, play: 0.05, weight: 0.65, strain: 0.95, reach: 0.14 },
        confused:   { warmth: 0.40, play: 0.25, weight: 0.40, strain: 0.45, reach: 0.25 },
        content:    { warmth: 0.80, play: 0.15, weight: 0.25, strain: 0.05, reach: 0.25 },
        crying:     { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.30, reach: 0.08 },
        dismayed:   { warmth: 0.25, play: 0.20, weight: 0.50, strain: 0.50, reach: 0.25 },
        dizzy:      { warmth: 0.40, play: 0.55, weight: 0.40, strain: 0.60, reach: 0.15 },
        focused:    { warmth: 0.45, play: 0.05, weight: 0.85, strain: 0.35, reach: 0.13 },
        frustrated: { warmth: 0.20, play: 0.15, weight: 0.55, strain: 0.90, reach: 0.15 },
        grin:       { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.18 },
        happy:      { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 },
        loving:     { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 },
        neutral:    { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 },
        queasy:     { warmth: 0.20, play: 0.10, weight: 0.60, strain: 0.60, reach: 0.25 },
        sad:        { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 },
        shocked:    { warmth: 0.30, play: 0.20, weight: 0.75, strain: 0.35, reach: 0.16 },
        star:       { warmth: 0.95, play: 0.60, weight: 0.35, strain: 0.05, reach: 0.15 },
        surprised:  { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 },
        unamused:   { warmth: 0.35, play: 0.35, weight: 0.30, strain: 0.55, reach: 0.25 },
        wink:       { warmth: 0.80, play: 0.90, weight: 0.10, strain: 0.10, reach: 0.18 },
      },
      suki:    {
        annoyed:   { warmth: 0.25, play: 0.30, weight: 0.35, strain: 0.80, reach: 0.25 },
        cheery:    { warmth: 0.90, play: 0.55, weight: 0.15, strain: 0.05, reach: 0.25 },
        dizzy:     { warmth: 0.40, play: 0.55, weight: 0.40, strain: 0.60, reach: 0.15 },
        excited:   { warmth: 0.95, play: 0.65, weight: 0.25, strain: 0.05, reach: 0.15 },
        focused:   { warmth: 0.45, play: 0.05, weight: 0.85, strain: 0.35, reach: 0.13 },
        happy:     { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 },
        loving:    { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 },
        neutral:   { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 },
        offering:  { warmth: 0.80, play: 0.30, weight: 0.25, strain: 0.10, reach: 0.25 },
        sad:       { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 },
        surprised: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 },
      },
      glimmer: {
        content:   { warmth: 0.80, play: 0.15, weight: 0.25, strain: 0.05, reach: 0.25 },
        crying:    { warmth: 0.05, play: 0.00, weight: 0.95, strain: 0.30, reach: 0.08 },
        dismayed:  { warmth: 0.25, play: 0.20, weight: 0.50, strain: 0.50, reach: 0.25 },
        focused:   { warmth: 0.45, play: 0.05, weight: 0.85, strain: 0.35, reach: 0.13 },
        grin:      { warmth: 0.95, play: 0.70, weight: 0.15, strain: 0.05, reach: 0.18 },
        happy:     { warmth: 0.85, play: 0.45, weight: 0.20, strain: 0.05, reach: 0.25 },
        loving:    { warmth: 0.90, play: 0.30, weight: 0.60, strain: 0.05, reach: 0.18 },
        neutral:   { warmth: 0.50, play: 0.25, weight: 0.25, strain: 0.15, reach: 0.32 },
        sad:       { warmth: 0.10, play: 0.05, weight: 0.80, strain: 0.25, reach: 0.20 },
        star:      { warmth: 0.95, play: 0.60, weight: 0.35, strain: 0.05, reach: 0.15 },
        surprised: { warmth: 0.50, play: 0.40, weight: 0.55, strain: 0.25, reach: 0.25 },
      },
    }.freeze

    # The faces that are the pet CROSS about something. Every one of them is a
    # scowl or a flat stare, and every one is aimed outward.
    #
    # They exist for friction in the exchange - the reply that missed the point,
    # the third go at the same request - and there they are honest. What they
    # must never be is the pet's answer to somebody who is themselves having a
    # bad time, because the nearest-face lookup MIRRORS the reading, and a
    # mirror held up to distress returns a scowl pointed at the person in it.
    # Nothing distinguishes that from being cross with them.
    #
    # A stretch about being stressed reads as high strain, the nearest Byte face
    # is then `annoyed`, and the pet wears a furrowed brow through its own offer
    # to cheer them up. See Buddy::Sentiment#skipped.
    IRRITATED = %i[angry annoyed frustrated unamused].freeze

    # Affection, which needs somebody to feel it toward — so these are skipped
    # on a turn nobody started (Buddy::Sentiment#skipped).
    #
    # The four axes measure how a moment FEELS and never what it is about, so a
    # warm weighty reading about a person and one about a company land within a
    # hundredth of each other. Whether anyone spoke is the only thing that
    # separates them, and without this a notification reaches these faces.
    TENDER = %i[loving hugging caring].freeze

    # Not what a finished errand looks like - so never the answer to having
    # just done something somebody asked for.
    #
    # `thumbs_up` is the one face that means it: "on it, got it, that's
    # sorted". All three of these sit within a tenth of it on all four axes,
    # and between them they took four turns in five of the band an everyday
    # errand reads in - leaving `thumbs_up` one in nine. So a timer got set and
    # the pet blushed, or put its glasses on, or went soft-eyed about it.
    #
    # - `neutral_blush` is being flattered, and nobody was.
    # - `nerd` is having worked something out, which running a tool is not.
    #
    # A skip and not a number, for the reason TENDER above is one: the axes
    # measure how a moment FEELS and cannot say what it is ABOUT, and what IS
    # known is that the turn did something. Both stay reachable on every turn
    # that only talked, which is where each of them is right.
    NOT_A_CONFIRMATION = %i[neutral_blush nerd].freeze

    # `content` used to need naming here too, for Byte and only Byte: its art
    # reused the row written for Moss's - a round mossy ball with its eyes
    # closed - and that row sits in the quiet warm corner every ordinary "done"
    # lands in, so a blob squashed flat and sparkling became the answer to
    # almost every errand. INDEX is keyed by theme now and Byte's row says what
    # Byte's drawing is, which takes it off the errand without a rule about it:
    # measured over the everyday band it went from more than one turn in six to
    # about one in twenty-five, which is the "occasionally" it was wanted at.

    AXES = %i[warmth play weight strain].freeze

    # `play` counts for less because it's the axis a reading is least sure
    # about - a person can be light about something heavy - and letting it pull
    # as hard as the others turned an earnest thank-you into a wink.
    AXIS_WEIGHTS = { warmth: 1.0, play: 0.7, weight: 1.0, strain: 0.9 }.freeze

    # This pet's row for a face. `theme` is required in anything measuring a
    # REAL pet: without it there is no telling which drawing is being asked
    # about, which is the whole reason the index is keyed by theme.
    def profile(face, theme)
      INDEX.dig(theme.to_s.to_sym, face.to_s.to_sym)
    end

    # One `reach` per face, stretched per axis by the same argument that
    # discounts them in AXIS_WEIGHTS: `play` is the axis a reading is least
    # sure about - a person can be light about something heavy - so a face has
    # to be forgiving about it or it answers nothing. `warmth` and `weight` are
    # the two that must actually agree, so they get the number as written.
    AXIS_REACH = { warmth: 1.0, play: 1.35, weight: 1.0, strain: 1.2 }.freeze

    # Does this reading fall inside the face's range on every axis?
    #
    # All four, with no partial credit. A face that is right about how good the
    # moment is and wrong about how much is at stake is not nearly right, it is
    # about a different moment - which is the failure `weight` was added to
    # stop and this is the same argument one step further on.
    def covers?(point, reading)
      AXES.all? { |axis|
        (point[axis].to_f - reading[axis].to_f).abs <= point[:reach].to_f * AXIS_REACH[axis]
      }
    end

    # Every face of this theme whose range covers the reading, nearest first.
    def candidates(theme, reading, skip: [])
      away = Array(skip).map(&:to_sym)
      (selectable(theme) - away).filter_map { |face|
        point = profile(face, theme)
        [face, distance(point, reading)] if point && covers?(point, reading)
      }.sort_by(&:last)
    end

    # Who is allowed to answer this reading.
    #
    # The ranges decide, EXCEPT that the closest face is always in - a range is
    # there to keep an irrelevant face out, not to leave a reading with nobody
    # to answer it. Twenty faces in a four-axis cube are sparse enough that a
    # strict gate strands most of the space, and a pet with no face is a worse
    # outcome than a pet wearing the nearest thing to what it was told.
    def pool(theme, reading, skip: [])
      best  = nearest(theme, reading, skip: skip)
      rows  = candidates(theme, reading, skip: skip)
      return rows if best.nil? || rows.any? { |face, _gap| face == best }

      point = profile(best, theme)
      ([[best, distance(point, reading)]] + rows).sort_by(&:last)
    end

    # The single closest face, range or no range. The deterministic answer, and
    # the fallback when a reading lands outside every range - a pet with no
    # face is worse than a pet wearing the nearest thing to what it was told.
    def nearest(theme, reading, skip: [])
      away = Array(skip).map(&:to_sym)
      scored = (selectable(theme) - away).filter_map { |face|
        point = profile(face, theme)
        [face, distance(point, reading)] if point
      }
      scored.min_by(&:last)&.first
    end

    # How flat the draw is. A weight is `1 / (distance + SOFTNESS)`, so this is
    # the distance at which a face is half as likely as a dead-on one.
    #
    # `distance` is the weighted SQUARE, so the numbers here are smaller than
    # they look: two faces a tenth apart on one axis are 0.01 apart, and at
    # 0.05 that draw is close to even. Turn it down and the best match wins
    # nearly always; turn it up and the pet stops answering the moment.
    SOFTNESS = 0.02

    # A face for this reading, chosen rather than computed.
    #
    # The nearest face is not the only true answer - three faces can all be
    # honest about one moment, and always taking the closest means the other
    # two are art nobody sees on the days they would have fitted. So the range
    # decides who is ALLOWED to answer and the draw decides which of them does,
    # weighted so the best match is still the likeliest by some way.
    #
    # `rng` is injectable so a spec can pin the draw; production passes
    # nothing and gets the default.
    def pick(theme, reading, skip: [], rng: Random)
      rows = pool(theme, reading, skip: skip)
      return nil if rows.empty?
      return rows.first.first if rows.one?

      weights = rows.map { |_face, gap| 1.0 / (gap + SOFTNESS) }
      roll    = rng.rand * weights.sum
      rows.each_with_index { |(face, _gap), i|
        roll -= weights[i]
        return face if roll <= 0
      }
      rows.first.first
    end

    def distance(point, reading)
      AXES.sum { |axis|
        delta = point[axis].to_f - reading[axis].to_f
        AXIS_WEIGHTS[axis] * delta * delta
      }
    end
  end
end
