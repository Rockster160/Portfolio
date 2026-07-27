module Buddy
  # Central point for buddy_expression writes. All expression changes go
  # through here so we don't get drift between features. Writes the column
  # AND broadcasts the change; multi-step transitions (e.g., celebrating →
  # encouraging → happy over 5s) enqueue delayed follow-up calls.
  module ExpressionState
    module_function

    # Union of every face across themes (Byte + Moss). Validation only — the
    # per-theme prompt (Personality.mood_block) is what constrains which of
    # these Buddy actually picks, so it never emits one its theme can't render.
    EXPRESSIONS = %i[
      neutral neutral_blush happy uwu encouraging annoyed sad crying thinking
      nerd focused celebrating sleeping sleeping_frown
    ].freeze

    def transition!(user, event, **_opts)
      return if user.nil?

      next_expression = expression_for(event)
      return if next_expression.nil?

      set(user, next_expression)
      schedule_followups(user, event)
    end

    def set(user, expression)
      expression = expression.to_s
      return unless EXPRESSIONS.include?(expression.to_sym)

      user.update_column(:buddy_expression, expression)
      broadcast(user, expression)
    end

    class << self
      private

      def expression_for(event)
        case event.to_sym
        when :turn_started        then :thinking
        when :turn_ended_clean    then :neutral   # resting default, not "cheesy grin happy"
        # Server-driven events use faces BOTH themes have (Byte lacks
        # focused/celebrating; Moss lacks annoyed/nerd) so they render for
        # either pet.
        when :proposals_awaiting  then :thinking
        when :proposals_executed  then :happy
        when :proposals_cancelled then :neutral
        when :tool_failed         then :thinking
        when :idle_long           then :neutral
        end
      end

      def schedule_followups(user, event)
        return unless event.to_sym == :proposals_executed

        Buddy::ExpressionCyclerJob.set(wait: 2.seconds).perform_later(user.id, "encouraging")
        Buddy::ExpressionCyclerJob.set(wait: 5.seconds).perform_later(user.id, "neutral")
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
