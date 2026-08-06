# Settles a stretch of conversation onto the held idea it was about, once that
# stretch is over (Buddy::IdeaDwell).
#
# Queued by Buddy::TurnDispatcher, twice for the two things that end a stretch:
# the end of a turn, where the check is whether the conversation has moved off
# the idea, and a compaction, which is the last moment the exchange is still in
# reach. Nothing schedules this and nothing polls — there is no stretch to
# settle that didn't arrive as a turn.
#
# It runs out here rather than inline because the note costs a model call, and
# the turn that queued it is holding that conversation's lock: a second message
# sent right behind the first would sit and wait out a call about a thought
# they've already moved on from.
class BuddyIdeaSettleWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 1

  def perform(conversation_id, over=false)
    conversation = ByteConversation.find_by(id: conversation_id)
    return if conversation.nil?

    Buddy::IdeaDwell.settle!(conversation, over: over)
  end
end
