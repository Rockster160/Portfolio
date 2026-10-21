module Buddy
  # The face PICKER, and the cross-cutting rules about faces. The per-pet data it
  # works on lives on the companions (Buddy::Companions::*), each of which sets
  # its own emotions in full — their summaries and their mood numbers. This file
  # keeps `index`/`profile`/`selectable`/`summary` as thin reads over those, and
  # owns the matching algorithm and the groupings (IRRITATED/TENDER/…) that are
  # about faces in general rather than any one pet.
  module Faces
    module_function

    # Driven by connection / usage-cap state, not moods Buddy chooses.
    SYSTEM = %i[sleeping].freeze

    # Transitional-only: the face shown WHILE a reply is being generated. Never
    # offered as a [[mood:]] (Buddy would otherwise rest on it), but renderable
    # so the server can set it during a turn.
    TRANSITIONAL = %i[thinking].freeze

    # A deliberate gesture the pet makes on cue, not a mood it settles into: the
    # wave shown on a greeting (see Buddy::ExpressionState#wave!). Like the system
    # faces it is art-on-disk only, never a declared emotion, so the sentiment
    # picker can't land on it — `valid?` sees it, `selectable` doesn't.
    GESTURES = %i[wave].freeze

    # Where the faces that are STATES rather than moods sit on the mood axes, so
    # a pet with no art for one wears the nearest face it does have instead of
    # going blank or snapping to neutral. Every other name takes its numbers
    # from the companions that declare it.
    STATE_POINTS = {
      thinking: { warmth: 0.45, play: 0.15, weight: 0.60, strain: 0.20 },
      pounce:   { warmth: 0.70, play: 0.90, weight: 0.25, strain: 0.25 },
      sleeping: { warmth: 0.55, play: 0.05, weight: 0.20, strain: 0.00 },
      wave:     { warmth: 0.85, play: 0.50, weight: 0.20, strain: 0.05 },
      clock:    { warmth: 0.45, play: 0.20, weight: 0.50, strain: 0.35 },
      alarm:    { warmth: 0.80, play: 0.65, weight: 0.55, strain: 0.25 },
    }.freeze

    # The faces the app itself puts on the pet rather than moods: asleep, mid
    # thought, a wave. Every pet can wear these - one with no drawing for one
    # wears its nearest face instead.
    def system_faces
      [*SYSTEM, *TRANSITIONAL, *GESTURES]
    end

    # The face a pet wears when asked for one by NAME (a task's `face`): a
    # system face always, any other only when this pet has that drawing. Nil
    # otherwise, so the pet keeps to its own feelings rather than a stand-in.
    def named(theme, name)
      name = name.to_s.strip.to_sym
      return nil if name.empty?
      return resolve(theme, name) if system_faces.include?(name)

      name if all(theme).include?(name)
    end

    # Is this a face any pet knows?
    def known?(name)
      known_names.include?(name.to_s.strip.to_sym)
    end

    # The face whose ART stands in for "thinking" on this pet. The expression
    # NAME stays `thinking` everywhere (so the client's transient/settle logic is
    # untouched); only which drawing it resolves to changes.
    def thinking(theme)
      resolve(theme, :thinking)
    end

    # The drawing this pet wears for an expression name: its own art when it has
    # some, else the drawn face nearest that name on the mood axes, else neutral.
    def resolve(theme, name)
      resolved_names(theme)[name.to_s.to_sym] || default
    end

    # { name => drawn face } for every expression name any pet knows, resolved
    # for this one. One disk read, so a page can resolve the whole set at once.
    def resolved_names(theme)
      drawn = all(theme)
      known_names.index_with { |name|
        drawn.include?(name) ? name : nearest_drawn(theme, drawn, name)
      }.compact
    end

    # Every expression name worth resolving: each pet's declared moods, each
    # pet's art, and the states above. Held per process outside development,
    # where the art can change under a running server.
    def known_names
      return @known_names if @known_names && !Rails.env.development?

      declared = index.values.flat_map(&:keys)
      art = Buddy::Themes.all.keys.flat_map { |theme| all(theme) }
      @known_names = (declared + art + STATE_POINTS.keys).uniq
    end

    # Where a name sits on the axes: a state's own numbers, else the average of
    # every companion that declares it. Nil for a name nobody has placed.
    def point_for(name)
      return STATE_POINTS[name] if STATE_POINTS.key?(name)

      rows = index.values.filter_map { |faces| faces[name] }
      return nil if rows.empty?

      AXES.index_with { |axis| rows.sum { |row| row[axis].to_f } / rows.size }
    end

    def nearest_drawn(theme, drawn, name)
      point = point_for(name)
      return nil if point.nil?

      pet = Buddy::Companion.find(theme).faces
      (pet.keys & drawn).min_by { |face| [distance(pet[face], point), face] }
    end

    def dir(theme)
      Rails.root.join("app/assets/images/buddy/#{theme.to_s.presence || "byte"}")
    end

    # Every face that has ART for a theme (png or svg), as symbols — read off
    # disk, so it includes the system faces (sleeping) and the transitional one
    # (thinking) when a pet has them. `valid?` is about "is there a drawing",
    # which is why it stays disk-backed while `selectable` comes from the
    # companion's declared moods.
    def all(theme)
      Dir[dir(theme).join("face_*.{png,svg}")]
        .map { |p| File.basename(p, ".*").delete_prefix("face_").to_sym }
        .uniq
    end

    # The moods Buddy may pick as a [[mood:]], from the companion's declared set
    # (which excludes the system/transitional faces by construction — they carry
    # no axes).
    def selectable(theme)
      Buddy::Companion.find(theme).faces.keys.sort
    end

    # A face Buddy is actually allowed to deliver as its mood.
    def selectable?(theme, expression)
      Buddy::Companion.find(theme).faces.key?(expression.to_s.to_sym)
    end

    # The resting face. Where the pet sits when nothing has moved it, and where
    # it returns after a lull (see BuddyExpressionResetWorker).
    def default
      :neutral
    end

    # Is there a drawing for this face? (Any face on disk, system ones included.)
    def valid?(theme, expression)
      all(theme).include?(expression.to_s.to_sym)
    end

    # Every pet's mood table, { theme => { face => {warmth,play,weight,strain,reach} } }.
    # Derived from the companions; was the hand-written INDEX literal.
    def index
      Buddy::Companion.all.transform_values(&:faces)
    end

    # What this pet's face IS, in a sentence — set per pet on the companion, so
    # two pets' same-named faces can read differently. Was the global HINTS map.
    def summary(face, theme)
      Buddy::Companion.find(theme).summaries[face.to_s.to_sym]
    end

    # This pet's row for a face: {warmth,play,weight,strain,reach} or nil.
    def profile(face, theme)
      Buddy::Companion.find(theme).faces[face.to_s.to_sym]
    end

    # The faces that are the pet CROSS about something — a scowl or flat stare,
    # aimed outward. They must never be the answer to somebody who is themselves
    # having a bad time: the nearest-face lookup MIRRORS the reading, and a
    # mirror held up to distress returns a scowl pointed at the person in it. See
    # Buddy::Sentiment#skipped.
    IRRITATED = %i[angry annoyed frustrated unamused].freeze

    # Affection, which needs somebody to feel it toward — so these are skipped on
    # a turn nobody started (Buddy::Sentiment#skipped). The axes measure how a
    # moment FEELS, never what it is about, so a warm weighty reading about a
    # person and one about a company land within a hundredth of each other;
    # whether anyone spoke is the only thing that separates them.
    TENDER = %i[loving hugging caring].freeze

    # Not what a finished errand looks like — so never the answer to having just
    # done something somebody asked for. `thumbs_up` is the one face that means
    # "on it, got it, sorted"; these three sit within a tenth of it and would
    # steal the turn, so they stay reachable only on a turn that merely talked.
    NOT_A_CONFIRMATION = %i[neutral_blush nerd bashful].freeze

    # What a pet does when it's tapped: a laugh, a blush, a plain happy face.
    # One of these the pet has is flashed at random (see Buddy::Pat).
    TAPPED = %i[happy grin cheery playful silly wink uwu neutral_blush bashful excited].freeze

    # The four axes a reading is taken on. (`reach` is the fifth value on a face
    # but not an axis — it is the range, not a dimension of the mood.)
    AXES = %i[warmth play weight strain].freeze

    # `play` counts for less because it's the axis a reading is least sure about
    # — a person can be light about something heavy — and letting it pull as hard
    # as the others turned an earnest thank-you into a wink.
    AXIS_WEIGHTS = { warmth: 1.0, play: 0.7, weight: 1.0, strain: 0.9 }.freeze

    # One `reach` per face, stretched per axis by the same argument that
    # discounts them in AXIS_WEIGHTS: `play` is the forgiving axis; `warmth` and
    # `weight` are the two that must actually agree, so they get the number as
    # written.
    AXIS_REACH = { warmth: 1.0, play: 1.35, weight: 1.0, strain: 1.2 }.freeze

    # Does this reading fall inside the face's range on every axis? All four,
    # with no partial credit: a face right about how good the moment is and wrong
    # about how much is at stake is about a different moment, not nearly right.
    def covers?(point, reading)
      AXES.all? { |axis|
        (point[axis].to_f - reading[axis].to_f).abs <= point[:reach].to_f * AXIS_REACH[axis]
      }
    end

    # Every face of this theme whose range covers the reading, nearest first.
    def candidates(theme, reading, skip: [])
      away = Array(skip).map(&:to_sym)
      pet  = Buddy::Companion.find(theme).faces
      # Sorted, so a tie in distance (sort_by and the weighted draw are not
      # tie-stable) always breaks the same way — the deterministic order the
      # picker was tuned against.
      (pet.keys.sort - away).filter_map { |face|
        point = pet[face]
        [face, distance(point, reading)] if covers?(point, reading)
      }.sort_by(&:last)
    end

    # Who is allowed to answer this reading. The ranges decide, EXCEPT that the
    # closest face is always in — a range is there to keep an irrelevant face
    # out, not to leave a reading with nobody to answer it.
    def pool(theme, reading, skip: [])
      best = nearest(theme, reading, skip: skip)
      rows = candidates(theme, reading, skip: skip)
      return rows if best.nil? || rows.any? { |face, _gap| face == best }

      point = profile(best, theme)
      ([[best, distance(point, reading)]] + rows).sort_by(&:last)
    end

    # The single closest face, range or no range. The deterministic answer, and
    # the fallback when a reading lands outside every range.
    def nearest(theme, reading, skip: [])
      away = Array(skip).map(&:to_sym)
      pet  = Buddy::Companion.find(theme).faces
      (pet.keys.sort - away).filter_map { |face|
        [face, distance(pet[face], reading)]
      }.min_by(&:last)&.first
    end

    # How flat the draw is. A weight is `1 / (distance + SOFTNESS)`, so this is
    # the distance at which a face is half as likely as a dead-on one. `distance`
    # is the weighted SQUARE, so the numbers are smaller than they look.
    SOFTNESS = 0.02

    # A face for this reading, chosen rather than computed. The range decides who
    # is ALLOWED to answer and the draw decides which of them does, weighted so
    # the best match is still the likeliest by some way. `rng` is injectable so a
    # spec can pin the draw; production passes nothing.
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
