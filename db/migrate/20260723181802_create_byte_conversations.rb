class CreateByteConversations < ActiveRecord::Migration[7.1]
  def change
    create_table :byte_conversations do |t|
      t.references :user, null: false, foreign_key: true, index: true
      t.string :name
      # 0=claude (default), 1=bash, 2=jarvis. Integer-backed enum so we can
      # extend without touching the column.
      t.integer :mode, null: false, default: 0
      t.boolean :archived, null: false, default: false
      t.jsonb :metadata, null: false, default: {}
      # Sort key for the drawer — updated whenever a message lands. Nullable
      # for freshly-created empty conversations.
      t.datetime :last_message_at
      t.timestamps
    end

    add_index :byte_conversations, [:user_id, :archived, :last_message_at],
      name: :index_byte_conversations_on_user_bucket_activity

    add_reference :byte_messages, :byte_conversation, foreign_key: true, index: true

    reversible do |dir|
      dir.up do
        # Backfill: give every existing user with byte messages a default
        # conversation named "Byte" and reparent all of their messages under
        # it. Runs in Ruby so we can name/order deterministically per user.
        say_with_time "Backfilling byte_conversations for existing messages" do
          user_ids = execute("SELECT DISTINCT user_id FROM byte_messages").map { |r| r["user_id"] }
          user_ids.each do |user_id|
            now = Time.current
            last_at = execute("SELECT MAX(created_at) AS c FROM byte_messages WHERE user_id = #{user_id.to_i}").first["c"]
            execute(<<~SQL)
              INSERT INTO byte_conversations
                (user_id, name, mode, archived, metadata, last_message_at, created_at, updated_at)
              VALUES
                (#{user_id.to_i}, 'Byte', 0, false, '{}'::jsonb,
                 #{last_at ? "'#{last_at}'" : "NULL"},
                 '#{now}', '#{now}')
              RETURNING id
            SQL
            convo_id = execute("SELECT id FROM byte_conversations WHERE user_id = #{user_id.to_i} ORDER BY id DESC LIMIT 1").first["id"]
            execute("UPDATE byte_messages SET byte_conversation_id = #{convo_id.to_i} WHERE user_id = #{user_id.to_i}")
          end
        end
      end
    end

    change_column_null :byte_messages, :byte_conversation_id, false
  end
end
