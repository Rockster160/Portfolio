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
  end
end
