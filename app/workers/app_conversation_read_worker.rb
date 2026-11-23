# Takes a read thread's notifications off the phone and resets its badge. Kept
# off the request that marked it read, since each push waits on Apple.
class AppConversationReadWorker
  include Sidekiq::Worker

  sidekiq_options retry: 1, queue: :default

  def perform(user_id, conversation_id)
    user = User.find_by(id: user_id)
    conversation = user&.byte_conversations&.find_by(id: conversation_id)
    return if conversation.nil?

    AppPush.conversation_read(user, conversation, ByteConversation.unread_total_for(user))
  end
end
