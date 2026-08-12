# Rests the pet's face after a lull (sidekiq-cron, every minute).
#
# Buddy's mood is deliberately persistent: it stays where a check-in, a mood
# call, or sleep put it, and nothing drifts it mid-conversation. An earlier
# cycler job DID drift it, and a face changing on its own read as a glitch.
#
# What that left behind was the opposite problem — an expression from an hour
# ago still sitting there, about a conversation that ended. This only touches
# threads that have been quiet, so it can never move the face out from under
# someone mid-exchange.
#
# Idempotent: ExpressionState#reset! no-ops on a conversation already resting,
# and resetting writes with update_column so it doesn't bump last_message_at
# and re-arm itself.
class BuddyExpressionResetWorker
  include Sidekiq::Worker

  sidekiq_options queue: :default, retry: 1

  # Short, because the face now MOVES on every action (Buddy::ExpressionState
  # #react!) rather than only when the model picks one — an expression that
  # arrives more often has to clear more often, or the pet just accumulates the
  # last thing that happened to it. Mid-exchange is protected by what this is
  # keyed on rather than by the length: anything either of them says bumps
  # `last_message_at`, so this can only fire on a thread nobody is using.
  IDLE_AFTER = 2.minutes

  def perform
    cutoff = IDLE_AFTER.ago

    stale_conversations(cutoff).find_each { |conversation|
      Buddy::ExpressionState.reset!(conversation)
    }
  end

  private

  def stale_conversations(cutoff)
    ByteConversation
      .where(mode: :buddy)
      .where.not(buddy_expression: [nil, "", Buddy::Faces.default.to_s])
      .where(last_message_at: ...cutoff)
  end
end
