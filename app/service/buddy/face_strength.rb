module Buddy
  # How strongly each thing that wants the pet's face wants it. The strongest
  # shows; the rest wait underneath and come back as stronger ones clear. The
  # board's hero (buddy/face_strength.js) and Buddy::BoardFace read the same
  # table, so a board opens wearing what its page will settle on.
  #
  # The mood sits in the middle. An idle mood wants nothing, so a dream's face
  # shows over it; a real mood outranks a dream but yields to a standing
  # condition. An alert or a dream can name its own strength (Jil's `Strength`
  # argument) to sit anywhere on this scale - a dream that should beat a mood,
  # an alert that should give way to one.
  module FaceStrength
    module_function

    IDLE    = 0
    DREAM   = 10
    MOOD    = 40
    ALERT   = 50
    # The most an alert, mood or dream may be raised with.
    MAX     = 100
    # Buddy asleep (disconnected, or out of usage). Above anything a task can
    # name, so nothing is ever shown over it.
    SLEEP   = 1000

    def mood(expression)
      Buddy::BoardFace.idle?(expression) ? IDLE : MOOD
    end

    # A named strength, or `fallback` when none was given. Zero and blank both
    # mean none, which is what a Jil call passes in the slot it isn't using.
    def named(value, fallback)
      number = value.to_s.strip.presence&.to_f
      return fallback if number.nil? || number <= 0

      number.clamp(1, MAX)
    end
  end
end
