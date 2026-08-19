# Runs Buddy::Compile once a conversation has gone quiet.
#
# Queued by Buddy::Compile.flag! on every turn carrying a person's message, for
# a quarter of an hour out. Because each turn re-flags, several of these can be in
# flight for one conversation at once — which is fine and is the design. The job
# re-reads `buddy_compile_after` and only does the work if that moment has
# arrived; otherwise it schedules itself for wherever the target moved to and
# exits. Nothing is cancelled and no jid is tracked.
#
# That shape is TimerFireWorker's, and it's chosen for the same reasons: it
# survives a dropped job, a restart mid-window, and two turns racing to flag,
# none of which jid bookkeeping survives.
class BuddyCompileWorker
  include Sidekiq::Worker

  sidekiq_options queue: :low, retry: 1

  def perform(conversation_id)
    conversation = ByteConversation.find_by(id: conversation_id)
    return if conversation.nil?

    Buddy::Compile.run!(conversation)
  end
end
