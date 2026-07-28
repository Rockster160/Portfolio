module Buddy
  # Central point for buddy_expression writes. All expression changes go
  # through here so we don't get drift between features. Writes the column
  # AND broadcasts the change; multi-step transitions (e.g., celebrating →
  # encouraging → happy over 5s) enqueue delayed follow-up calls.
  module ExpressionState
    module_function

    def transition!(user, event, **_opts)
      return if user.nil?

      next_expression = expression_for(event)
      return if next_expression.nil?

      set(user, next_expression)
      schedule_followups(user, event)
    end

    def set(user, expression)
      expression = expression.to_s
      # Validate against the faces THIS user's theme actually renders — Byte
      # and Moss have different sets, so a single hardcoded list would either
      # reject valid faces or accept ones that render blank.
      return unless Buddy::Faces.valid?(user.buddy_theme, expression)

      user.update_column(:buddy_expression, expression)
      broadcast(user, expression)
    end

    class << self
      private

      def expression_for(event)
        case event.to_sym
        # `thinking` is transitional ONLY — the "working on your reply" face,
        # shown until the reply lands (turn_ended / a mood marker replaces it).
        # No settled state ever rests on it, or the pet looks stuck mid-thought.
        when :turn_started        then :thinking
        when :turn_ended_clean    then :neutral   # resting default, not "cheesy grin happy"
        # Server-driven events use faces BOTH themes have (Byte lacks
        # focused/celebrating; Moss lacks annoyed/nerd) so they render for
        # either pet.
        when :proposals_awaiting  then :neutral   # waiting on the user — a settled rest, not mid-thought
        when :proposals_executed  then :happy
        when :proposals_cancelled then :neutral
        when :tool_failed         then :sad       # something didn't go through — settled concern, not stuck thinking
        when :idle_long           then :neutral
        end
      end

      def schedule_followups(user, event)
        return unless event.to_sym == :proposals_executed

        # Wind down to the resting baseline. `happy` (set now) and `neutral`
        # are the only faces both themes share for a server-driven step —
        # `encouraging` would render blank on Moss.
        Buddy::ExpressionCyclerJob.set(wait: 4.seconds).perform_later(user.id, "neutral")
      end

      def broadcast(user, expression)
        MonitorChannel.broadcast_to(user, {
          id:      :byte,
          channel: :byte,
          data:    { kind: :buddy_expression, expression: expression },
        })
      rescue => e
        Rails.logger.warn("[Buddy] expression broadcast failed: #{e.class}: #{e.message}")
      end
    end
  end
end
