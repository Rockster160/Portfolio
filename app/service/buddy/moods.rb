module Buddy
  # A mood a task asks a board's pet to wear, given as a point on the faces' own
  # axes (Buddy::Faces::AXES) rather than as a face name. A name is one pet's
  # drawing; a point means the same thing to every pet, and each one answers it
  # with its own nearest face - one pet's spellbook, another's laptop.
  #
  # Only the axes given count, so a mood can care about strain and nothing else.
  # `reach` is how far from the point a face may sit and still be chosen; without
  # one, each face's own reach decides, as it does for Buddy's own moods. The
  # face is drawn from those in reach, nearest likeliest, with a seed so the pet
  # keeps the same one while the mood stands.
  module Moods
    module_function

    SETTINGS = [*Buddy::Faces::AXES, :reach].freeze

    # Where a drawn state face sits when it is a candidate. The states carry a
    # point (Buddy::Faces::STATE_POINTS) but no reach of their own.
    STATE_REACH = 0.15

    # The settings worth keeping from a Jil block, as { "warmth" => 0.2, ... },
    # each clamped to 0..1. Nil when no axis was given: a reach alone points at
    # nothing.
    def reading(settings)
      settings = settings.to_h.symbolize_keys
      mood = SETTINGS.each_with_object({}) { |axis, kept|
        value = settings[axis]
        next if value.nil? || value.to_s.strip.empty?

        kept[axis.to_s] = value.to_f.clamp(0.0, 1.0).round(3)
      }
      mood if Buddy::Faces::AXES.any? { |axis| mood.key?(axis.to_s) }
    end

    # The face this pet wears for the mood. `seed` keeps the draw steady.
    def face(theme, mood, seed:)
      mood = mood.to_h.symbolize_keys
      axes = Buddy::Faces::AXES.select { |axis| mood.key?(axis) }
      return nil if axes.empty?

      rows = pool(points(theme), mood, axes)
      return nil if rows.empty?

      draw(rows, Random.new(Digest::MD5.hexdigest(seed.to_s).to_i(16)))
    end

    # { theme => face } for every pet, so any board can paint it without asking.
    def faces(mood, seed:)
      Buddy::Companion.all.keys.each_with_object({}) { |theme, faces|
        face = face(theme, mood, seed:)
        faces[theme.to_s] = face.to_s if face
      }
    end

    # Never a mood's answer: a gesture is made on cue, and thinking is the face
    # of a reply on its way.
    NOT_MOODS = [*Buddy::Faces::GESTURES, *Buddy::Faces::TRANSITIONAL].freeze

    # Every face this pet has a drawing AND a point for: its declared moods, plus
    # the drawn states (sleeping and the like), which a mood may also land on.
    def points(theme)
      drawn = Buddy::Faces.all(theme) - NOT_MOODS
      declared = Buddy::Companion.find(theme).faces.slice(*drawn)
      states = Buddy::Faces::STATE_POINTS.slice(*drawn).transform_values { |point|
        point.merge(reach: STATE_REACH)
      }
      states.merge(declared)
    end

    # The faces allowed to answer, nearest first. The nearest is always in, so a
    # mood never leaves the pet with nothing to wear.
    def pool(points, mood, axes)
      rows = points.map { |face, point| [face, gap(point, mood, axes), point] }
      rows = rows.sort_by { |face, gap, _| [gap, face] }
      return [] if rows.empty?

      inside = rows.select { |_, _, point| within?(point, mood, axes) }
      inside = [rows.first] + inside unless inside.include?(rows.first)
      inside.map { |face, gap, _| [face, gap] }
    end

    def within?(point, mood, axes)
      reach = mood[:reach] || point[:reach]
      axes.all? { |axis|
        (point[axis].to_f - mood[axis].to_f).abs <= reach.to_f * Buddy::Faces::AXIS_REACH[axis]
      }
    end

    def gap(point, mood, axes)
      axes.sum { |axis|
        delta = point[axis].to_f - mood[axis].to_f
        Buddy::Faces::AXIS_WEIGHTS[axis] * delta * delta
      }
    end

    # Weighted the way Buddy::Faces.pick weights its own draw.
    def draw(rows, rng)
      return rows.first.first if rows.one?

      weights = rows.map { |_, gap| 1.0 / (gap + Buddy::Faces::SOFTNESS) }
      roll = rng.rand * weights.sum
      rows.each_with_index { |(face, _), i|
        roll -= weights[i]
        return face if roll <= 0
      }
      rows.first.first
    end
  end
end
