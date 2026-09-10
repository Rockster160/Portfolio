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

  # Mid-exchange is protected by what this is keyed on rather than by the
  # length: every message bumps `last_message_at` (ByteMessage
  # #bump_conversation_activity), so this can only fire on a thread nobody is
  # using, and the face survives an exchange however long it runs.
  #
  # It was 2 minutes, chosen when the face moved on its own after every action
  # and so had to clear often. It doesn't any more - Buddy::Sentiment reads the
  # conversation and chooses - and 2 minutes turned out to be shorter than a
  # conversation: 43% of the things Rocco typed over a fortnight arrived more
  # than 2 minutes after the previous message, so the pet had already gone
  # blank between nearly half of them. That is a lull to a cron job and a pause
  # to a person.
  IDLE_AFTER = 5.minutes

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
