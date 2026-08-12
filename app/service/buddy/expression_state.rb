module Buddy
  # Central point for the pet's expression. Two distinct concepts live here,
  # and keeping them separate is the whole point:
  #
  #   * The MOOD — `byte_conversations.buddy_expression`. A persistent face that
  #     stays put until something DELIBERATELY changes it: a `[[mood: X]]`
  #     marker, an explicit check-in, or sleep/wake. It does NOT drift back to a
  #     default on its own. `set` is the only path that writes the column. Mood
  #     is per-conversation — each Buddy thread rests on its own face.
  #
  #   * "thinking" — a TRANSIENT overlay shown while a turn is in flight. It is
  #     never written to the column (so it can't clobber the stored mood) and
  #     never persists: the client drops it the instant reply text starts
  #     streaming, and `settle!` is a server-side backstop that re-asserts the
  #     stored mood at turn end.
  #
  # Broadcasts carry `transient:` so the client knows which concept it's being
  # told about: `transient: true` → overlay only (don't touch stored mood);
  # `transient: false` → a real mood the client should remember and rest on.
  # They also carry `conversation_id` so the client only paints the face when
  # that thread is the one on screen.
  module ExpressionState
    module_function

    # Turn starting: show the "thinking" overlay without touching the mood.
    def thinking!(conversation)
      return if conversation.nil?

      broadcast(conversation, :thinking, transient: true)
    end

    # Turn ended (or any point we want the pet off "thinking"): re-assert the
    # stored mood so the client drops the overlay. The mood itself is unchanged
    # — this never picks a default, it just echoes what's already persisted.
    def settle!(conversation)
      return if conversation.nil?

      broadcast(conversation, conversation.buddy_expression, transient: false)
    end

    # Persist + broadcast a real mood change. The ONLY writer of the column.
    # Used by `[[mood:]]` markers, check-ins, and sleep/wake.
    def set(conversation, expression)
      return if conversation.nil?

      expression = expression.to_s
      # Validate against the faces THIS conversation's theme actually renders —
      # Byte and Moss have different sets, so a single hardcoded list would
      # either reject valid faces or accept ones that render blank.
      return unless Buddy::Faces.valid?(conversation.buddy_theme, expression)

      conversation.update_column(:buddy_expression, expression)
      broadcast(conversation, expression, transient: false)
    end

    # Something actually RAN this turn, so the pet reacts to it.
    #
    # A companion that does the thing and keeps a flat face reads as a machine
    # accepting a command. Doing something for someone is the most expressive
    # moment there is, so an action never leaves the pet on `neutral`.
    #
    # Only ever moves a pet that's RESTING. A face the model chose this turn is
    # a deliberate read of the room - sitting with something heavy while it
    # quietly cancels an alarm - and a generic pleased-with-itself face
    # stamped over the top of that is the "face changed on its own" glitch this
    # module exists to prevent. So this is a FLOOR, not an override.
    def react!(conversation)
      return if conversation.nil?
      return unless [nil, "", Buddy::Faces.default.to_s].include?(conversation.buddy_expression)

      mood = Buddy::VoiceLines.acted_mood(conversation.buddy_theme)
      set(conversation, mood) if mood
    end

    # Back to resting after a stretch of silence (BuddyExpressionResetWorker).
    #
    # The mood is deliberately persistent — it stays where a check-in, a marker,
    # or sleep put it rather than drifting on its own, because a face that
    # changes unprompted reads as a glitch (that was the old cycler job). But a
    # mood set an hour ago has stopped being a mood and become a leftover, so
    # after a lull the pet rests rather than holding an expression about a
    # conversation that ended.
    def reset!(conversation)
      return if conversation.nil?
      return if conversation.buddy_expression.to_s == Buddy::Faces.default.to_s

      set(conversation, Buddy::Faces.default)
    end

    # Back-compat shim for the old event-based callers. Turn start shows the
    # thinking overlay; every other event just settles the pet back onto its
    # stored mood. No event forces a mood any more — the mood persists until
    # a marker / check-in / sleep explicitly moves it. (This is the fix for
    # "the face changed for a second then reverted": nothing reverts it now.)
    def transition!(conversation, event, **_opts)
      return if conversation.nil?

      event.to_sym == :turn_started ? thinking!(conversation) : settle!(conversation)
    end

    class << self
      private

      def broadcast(conversation, expression, transient:)
        MonitorChannel.broadcast_to(conversation.user, {
          id:      :byte,
          channel: :byte,
          data:    {
            kind:            :buddy_expression,
            conversation_id: conversation.id,
            expression:      expression.to_s,
            transient:       transient,
          },
        })
      rescue StandardError => e
        Rails.logger.warn("[Buddy] expression broadcast failed: #{e.class}: #{e.message}")
      end
    end
  end
end
