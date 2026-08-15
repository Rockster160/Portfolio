class CreateByteMessageShares < ActiveRecord::Migration[7.1]
  def change
    create_table :byte_message_shares do |t|
      t.references :byte_message,      null: false, foreign_key: true
      t.references :byte_conversation, null: false, foreign_key: true
      t.references :user,              null: false, foreign_key: true

      t.timestamps
    end

    # One share per message per conversation. Sharing the same doorbell frame
    # twice into one thread would show it twice, and the delivery paths are
    # idempotent-by-upsert on the strength of this.
    add_index :byte_message_shares, %i[byte_message_id byte_conversation_id],
      unique: true, name: "index_byte_message_shares_on_message_and_conversation"
    # The read path: "everything shared INTO this conversation", ordered by the
    # message's own created_at, so a share never reorders the thread.
    add_index :byte_message_shares, %i[byte_conversation_id byte_message_id]
  end
end
