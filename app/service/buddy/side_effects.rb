module Buddy
  # Applies the non-checkbox markers Buddy can emit ([[mood: X]],
  # [[remember: X]]). Unlike proposals, these fire immediately — no
  # user confirmation — so the vocabulary is deliberately small and
  # non-destructive.
  #
  # Adding a new side-effect verb:
  #   1. Add it to Buddy::MarkerParser::SIDE_EFFECT_RX (alternation).
  #   2. Add a `when :verb` branch here.
  #   3. Teach it in the persona's Rules of the House.
  module SideEffects
    module_function

    def apply(user, side_effects)
      Array(side_effects).each do |eff|
        case eff[:verb]
        when :mood     then apply_mood(user, eff[:body])
        when :remember then apply_remember(user, eff[:body])
        when :forget   then apply_forget(user, eff[:body])
        end
      rescue => e
        Rails.logger.warn("[Buddy::SideEffects] #{eff[:verb]} failed: #{e.class}: #{e.message}")
      end
    end

    # `[[mood: <one of the five expressions>]]` — shifts the pet's face
    # and broadcasts. The pet expression IS the mood state; the field
    # (users.buddy_expression) persists across turns and rides in every
    # context block, so no shadow log or event trail is needed.
    def apply_mood(user, body)
      expression = body.to_s.downcase.strip
      valid = Buddy::Faces.valid?(user.buddy_theme, expression)
      # Observability: mood markers are otherwise trail-less (stripped from the
      # body, set via update_column). This line is how we can actually answer
      # "is Buddy using expressions?" — grep prod for `[Buddy::mood]`.
      Rails.logger.info(
        "[Buddy::mood] user=#{user.id} theme=#{user.buddy_theme} requested=#{expression.inspect} " \
        "valid=#{valid} current=#{user.buddy_expression.inspect}"
      )
      return unless valid
      return if user.buddy_expression == expression  # no-op if unchanged

      Buddy::ExpressionState.set(user, expression)
    end

    # `[[remember: <fact>]]` — writes a durable BuddyMemory row. Bounded
    # to 500 chars (matches the model validation) so an accidental
    # paragraph-length marker doesn't create a giant row.
    def apply_remember(user, body)
      fact = body.to_s.strip
      return if fact.empty?

      BuddyMemory.create!(
        user:    user,
        content: fact.first(500),
      )
    end

    # `[[forget: <substring or id>]]` — prunes matching memory rows. If
    # the body is a bare integer, deletes by id; otherwise deletes rows
    # whose content contains the substring (case-insensitive). Cap the
    # damage at 5 rows per marker so a stray "forget everything" can't
    # nuke the whole history.
    def apply_forget(user, body)
      needle = body.to_s.strip
      return if needle.empty?

      scope = user.buddy_memories rescue BuddyMemory.where(user: user)
      matches = if needle.match?(/\A\d+\z/)
        scope.where(id: needle.to_i)
      else
        scope.where("LOWER(content) LIKE ?", "%#{needle.downcase}%")
      end
      matches.order(created_at: :desc).limit(5).destroy_all
    end
  end
end
