class AddBuddyCompileAndTopicToByteConversations < ActiveRecord::Migration[7.1]
  def change
    # The background compile debounce. A turn that notices something worth
    # keeping sets `buddy_compile_after` roughly an hour out; every further
    # message pushes it back, so the compile only runs once the conversation has
    # actually gone quiet. The worker re-reads the column and reschedules rather
    # than tracking and cancelling Sidekiq jids (same shape as TimerFireWorker).
    add_column(:byte_conversations, :buddy_compile_after, :datetime)
    add_column(:byte_conversations, :buddy_compiled_at, :datetime)

    # Topic-scoped short-term memory: what this thread is on RIGHT NOW, in a few
    # sentences. Distilled into long-term and cleared when Buddy::IdeaDwell says
    # the conversation has moved off it. Verbatim recent messages are untouched
    # underneath this — it's an addition to history, not a replacement.
    add_column(:byte_conversations, :buddy_topic, :text)
    add_column(:byte_conversations, :buddy_topic_at, :datetime)

    add_index(:byte_conversations, :buddy_compile_after, where: "buddy_compile_after IS NOT NULL")
  end
end
