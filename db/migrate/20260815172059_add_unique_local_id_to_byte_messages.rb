class AddUniqueLocalIdToByteMessages < ActiveRecord::Migration[7.1]
  # `local_id` is the idempotency key the client already mints for every
  # composed message, and its outbound queue retries on any uncertain outcome.
  # ByteMessageIntake now checks for a repeat before creating, but a check is
  # not a guarantee: two requests in flight together both pass it. This is what
  # actually settles it.
  def up
    # Two pairs already exist in prod (one send delivered twice, in July and
    # again in August), so the index can't be added over the data as it stands.
    #
    # The local_id is CLEARED on the later row rather than the row being
    # deleted: it's somebody's message, the duplicate reply to it is already in
    # the thread, and quietly removing chat history to satisfy a constraint is a
    # worse trade than leaving a row whose idempotency key is blank. Blank ones
    # are excluded from the index anyway, which is exactly what makes this work.
    execute(<<~SQL.squish)
      UPDATE byte_messages SET metadata = metadata - 'local_id'
      WHERE id IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (
            PARTITION BY byte_conversation_id, metadata->>'local_id' ORDER BY id
          ) AS n
          FROM byte_messages WHERE metadata->>'local_id' IS NOT NULL
        ) ranked WHERE ranked.n > 1
      )
    SQL

    add_index :byte_messages, "byte_conversation_id, (metadata->>'local_id')",
      unique: true,
      where:  "metadata->>'local_id' IS NOT NULL",
      name:   "index_byte_messages_on_conversation_and_local_id"
  end

  def down
    remove_index :byte_messages, name: "index_byte_messages_on_conversation_and_local_id"
  end
end
