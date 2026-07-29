module Buddy
  # Central point for the pet's expression. Two distinct concepts live here,
  # and keeping them separate is the whole point:
  #
  #   * The MOOD — `users.buddy_expression`. A persistent face that stays put
  #     until something DELIBERATELY changes it: a `[[mood: X]]` marker, an
  #     explicit check-in, or sleep/wake. It does NOT drift back to a default
  #     on its own. `set` is the only path that writes the column.
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
  module ExpressionState
    module_function

    # Turn starting: show the "thinking" overlay without touching the mood.
    def thinking!(user)
      return if user.nil?

      broadcast(user, :thinking, transient: true)
    end

    # Turn ended (or any point we want the pet off "thinking"): re-assert the
    # stored mood so the client drops the overlay. The mood itself is unchanged
    # — this never picks a default, it just echoes what's already persisted.
    def settle!(user)
      return if user.nil?

      broadcast(user, user.buddy_expression, transient: false)
    end

    # Persist + broadcast a real mood change. The ONLY writer of the column.
    # Used by `[[mood:]]` markers, check-ins, and sleep/wake.
    def set(user, expression)
      expression = expression.to_s
      # Validate against the faces THIS user's theme actually renders — Byte
      # and Moss have different sets, so a single hardcoded list would either
      # reject valid faces or accept ones that render blank.
      return unless Buddy::Faces.valid?(user.buddy_theme, expression)

      user.update_column(:buddy_expression, expression)
      broadcast(user, expression, transient: false)
    end

    # Back-compat shim for the old event-based callers. Turn start shows the
    # thinking overlay; every other event just settles the pet back onto its
    # stored mood. No event forces a mood any more — the mood persists until
    # a marker / check-in / sleep explicitly moves it. (This is the fix for
    # "the face changed for a second then reverted": nothing reverts it now.)
    def transition!(user, event, **_opts)
      return if user.nil?

      event.to_sym == :turn_started ? thinking!(user) : settle!(user)
    end

    class << self
      private

      def broadcast(user, expression, transient:)
        MonitorChannel.broadcast_to(user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :buddy_expression, expression: expression.to_s, transient: transient },
        })
      rescue StandardError => e
        Rails.logger.warn("[Buddy] expression broadcast failed: #{e.class}: #{e.message}")
      end
    end
  end
end
