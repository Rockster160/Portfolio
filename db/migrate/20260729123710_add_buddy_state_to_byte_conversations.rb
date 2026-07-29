class AddBuddyStateToByteConversations < ActiveRecord::Migration[7.1]
  # The pet's identity + short-term state moves off the user and onto each
  # conversation, so every Buddy thread is its own companion. buddy_memories is
  # a small per-conversation notes block Buddy self-manages via [[note:]].
  def up
    add_column :byte_conversations, :buddy_theme, :string, null: false, default: "byte"
    add_column :byte_conversations, :buddy_expression, :string, null: false, default: "neutral"
    add_column :byte_conversations, :buddy_sleep_until, :datetime
    add_column :byte_conversations, :buddy_memories, :text

    # Backfill existing Buddy threads from the user's current values so nobody's
    # pet resets on deploy. mode 3 == :buddy (ByteConversation.modes[:buddy]).
    execute(<<~SQL)
      UPDATE byte_conversations c
      SET buddy_theme       = u.buddy_theme,
          buddy_expression  = u.buddy_expression,
          buddy_sleep_until = u.buddy_sleep_until
      FROM users u
      WHERE c.user_id = u.id
        AND c.mode = 3
    SQL

    # Rocco's household member 58128 gets Moss by default.
    execute(<<~SQL)
      UPDATE byte_conversations
      SET buddy_theme = 'moss'
      WHERE mode = 3 AND user_id = 58128
    SQL
  end

  def down
    remove_column :byte_conversations, :buddy_theme
    remove_column :byte_conversations, :buddy_expression
    remove_column :byte_conversations, :buddy_sleep_until
    remove_column :byte_conversations, :buddy_memories
  end
end
