module Buddy
  # Single source of truth for which expression faces exist, per theme.
  # Derived from the actual image files so the prompt vocabulary, the
  # validation gate, and the rendered set never drift as faces are added.
  module Faces
    module_function

    # Driven by connection / usage-cap state, not moods Buddy chooses.
    SYSTEM = %i[sleeping sleeping_frown].freeze

    def dir(theme)
      Rails.root.join("app/assets/images/buddy/#{theme.to_s.presence || 'byte'}")
    end

    # Every face that exists for a theme (png or svg), as symbols.
    def all(theme)
      Dir[dir(theme).join("face_*.{png,svg}")]
        .map { |p| File.basename(p, ".*").delete_prefix("face_").to_sym }
        .uniq
    end

    # Faces Buddy may pick as a [[mood:]] — excludes the system faces.
    def selectable(theme)
      (all(theme) - SYSTEM).sort
    end

    # Faces every theme can render — safe for SERVER-driven expression sets
    # (proposal states, check-in) that must show up on both Byte and Moss.
    def common
      %i[neutral happy sad crying thinking]
    end

    def valid?(theme, expression)
      all(theme).include?(expression.to_s.to_sym)
    end
  end
end
