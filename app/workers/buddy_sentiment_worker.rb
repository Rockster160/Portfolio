# Picks the pet's face when the model didn't.
#
# Off the turn on purpose: the reply has already been delivered by the time this
# is enqueued, so nothing is waiting on the call, and an expression arriving a
# beat later is how an ambient thing should arrive. See Buddy::Sentiment for why
# it's a model call at all.
class BuddySentimentWorker
  include Sidekiq::Worker

  # No retries. A face is about a moment, and by the time a retry ran the
  # conversation has moved on - re-reading it later would put an expression up
  # about something already finished, which is the exact drift the mood being
  # sticky is meant to prevent. Buddy::Sentiment#settle! re-checks the gate
  # anyway, so a late run is a no-op rather than a wrong face.
  sidekiq_options queue: :default, retry: 0

  # Positional, because Sidekiq serialises the argument list to JSON.
  #
  # `unprompted` has a default and the others don't: jobs enqueued before it
  # existed are still in the queue with three arguments, and `false` is what
  # they mean.
  # rubocop:disable Style/OptionalBooleanParameter -- Sidekiq args are positional
  def perform(conversation_id, acted, landed, unprompted=false)
    conversation = ByteConversation.find_by(id: conversation_id)
    return if conversation.nil?

    Buddy::Sentiment.settle!(conversation, acted: acted, landed: landed, unprompted: unprompted)
  end
  # rubocop:enable Style/OptionalBooleanParameter
end
