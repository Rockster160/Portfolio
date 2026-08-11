class AddLastReadAtToByteConversations < ActiveRecord::Migration[7.1]
  # Unread was a counter in the page's memory, so it was gone on reload and the
  # iOS home-screen badge had nothing to read at all — a message that arrived
  # while the app was closed could never be counted, because counting happened
  # only in response to a live broadcast.
  #
  # A timestamp rather than a last-read message id: messages are only ever
  # appended, "everything after this moment" is the question being asked, and a
  # deleted or edited row can't strand the marker on something that no longer
  # exists.
  #
  # Backfilled to `last_message_at` rather than left NULL, so nobody opens the
  # app after this ships to a badge counting their entire history.
  def up
    add_column(:byte_conversations, :last_read_at, :datetime)
    execute("UPDATE byte_conversations SET last_read_at = COALESCE(last_message_at, created_at)")
  end

  def down
    remove_column(:byte_conversations, :last_read_at)
  end
end
