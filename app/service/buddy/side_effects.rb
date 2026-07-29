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

    # `conversation` is the thread the reply landed in. Per-conversation verbs
    # (mood, note) act on it; user-global verbs (remember, forget, stash) act on
    # `conversation.user`.
    def apply(conversation, side_effects)
      user = conversation.user
      Array(side_effects).each do |eff|
        case eff[:verb]
        when :mood     then apply_mood(conversation, eff[:body])
        when :note     then apply_note(conversation, eff[:body])
        when :remember then apply_remember(user, eff[:body])
        when :forget   then apply_forget(user, eff[:body])
        when :stash    then apply_stash(user, eff[:body])
        end
      rescue StandardError => e
        Rails.logger.warn("[Buddy::SideEffects] #{eff[:verb]} failed: #{e.class}: #{e.message}")
      end
    end

    # `[[mood: <one of the expressions>]]` — shifts this thread's pet face
    # and broadcasts. The pet expression IS the mood state; the field
    # (byte_conversations.buddy_expression) persists across turns and rides in
    # every context block, so no shadow log or event trail is needed.
    def apply_mood(conversation, body)
      expression = body.to_s.downcase.strip
      theme = conversation.buddy_theme
      # `selectable?` not `valid?` — a delivered mood may never be a
      # system/transitional face (e.g. `thinking`), even if the model emits
      # one off-list. Those would leave the pet resting on a non-mood face.
      valid = Buddy::Faces.selectable?(theme, expression)
      # Observability: mood markers are otherwise trail-less (stripped from the
      # body, set via update_column). This line is how we can actually answer
      # "is Buddy using expressions?" — grep prod for `[Buddy::mood]`.
      Rails.logger.info(
        "[Buddy::mood] user=#{conversation.user_id} conversation=#{conversation.id} " \
        "theme=#{theme} requested=#{expression.inspect} " \
        "valid=#{valid} current=#{conversation.buddy_expression.inspect}",
      )
      return unless valid
      return if conversation.buddy_expression == expression  # no-op if unchanged

      Buddy::ExpressionState.set(conversation, expression)
    end

    # `[[note: <fact>]]` — appends a line to this conversation's small notes
    # block (byte_conversations.buddy_memories). Per-conversation and
    # short-lived by nature ("keep this thread strictly work"); durable global
    # facts go through `[[remember:]]` instead. Fires silently.
    def apply_note(conversation, body)
      Buddy::ConversationNotes.append(conversation, body)
    end

    # `[[stash: id=N category=work summary=...]]` — records Buddy's sort of a
    # brain-dump idea (category + summary). Fires silently; the friendly "filed
    # under X" line is Buddy's prose, not this marker.
    def apply_stash(user, body)
      args = Buddy::MarkerParser.parse_args(body)
      Buddy::Stash.apply_sort(user, args)
    end

    # `[[remember: <fact>]]` — writes a durable BuddyMemory row. Bounded to 500
    # chars (matches the model validation) so an accidental paragraph-length
    # marker doesn't create a giant row.
    #
    # Two optional refinements:
    #   * Short-term: `[[remember: <fact> | <duration>]]` (e.g. "| 2 weeks",
    #     "| 3 days", "| today") sets an expiry so the fact self-prunes. No
    #     pipe = a durable fact that never expires.
    #   * Reinforcement: if we already hold this fact (near-duplicate), bump it
    #     instead of storing a copy, so re-mentions keep it fresh + high.
    def apply_remember(user, body)
      fact, ttl = split_memory_ttl(body)
      return if fact.empty?

      existing = find_similar_memory(user, fact)
      if existing
        existing.reinforce!
        existing.update_columns(expires_at: ttl, updated_at: Time.current) if ttl
        return
      end

      BuddyMemory.create!(
        user:         user,
        content:      fact.first(500),
        expires_at:   ttl,
        last_used_at: Time.current,
      )
    end

    # Split an optional trailing `| <duration>` off a remember body and turn it
    # into an absolute expiry. Pipe is regex-safe inside the marker (the marker
    # body just can't contain `]`). Unparseable duration → treated as durable.
    def split_memory_ttl(body)
      raw = body.to_s.strip
      return [raw, nil] unless raw.include?("|")

      fact, _sep, dur = raw.rpartition("|")
      [fact.strip, parse_duration(dur)]
    rescue StandardError
      [raw, nil]
    end

    def parse_duration(text)
      t = text.to_s.strip.downcase
      return Time.current.end_of_day if t == "today"
      return Time.current.tomorrow.end_of_day if t == "tomorrow"

      m = t.match(/\A(\d+)\s*(day|week|month|year|hour)s?\z/)
      return nil unless m

      Time.current + m[1].to_i.public_send("#{m[2]}s")
    end

    # An active memory that's effectively the same fact - exact (normalized)
    # match, or one clearly contains the other. Conservative on purpose: only
    # obvious re-mentions reinforce; anything novel becomes its own row.
    def find_similar_memory(user, fact)
      norm = fact.to_s.downcase.gsub(/\s+/, " ").strip
      return nil if norm.length < 8

      BuddyMemory.where(user: user).active.find { |m|
        other = m.content.to_s.downcase.gsub(/\s+/, " ").strip
        other == norm || other.include?(norm) || norm.include?(other)
      }
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
