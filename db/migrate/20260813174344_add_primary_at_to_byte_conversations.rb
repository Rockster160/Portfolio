class AddPrimaryAtToByteConversations < ActiveRecord::Migration[7.1]
  # Which Buddy thread everything self-initiated lands in.
  #
  # A timestamp rather than a boolean: `primary` is a reserved word in Postgres,
  # NULL/not-NULL says the same thing, and knowing WHEN it was chosen is free
  # here and impossible to add back later.
  #
  # The partial unique index is the point of using a column at all. Exclusivity
  # was previously enforced only by `pin_primary!` doing clear-then-set in a
  # transaction — which any other writer could bypass, and one of them could:
  # `update_conversation` merges client-supplied `metadata` onto the row, so a
  # hand-rolled PATCH could have marked three threads at once. Two primaries
  # would make where a briefing lands depend on row order, and that is the
  # ordering bug this whole feature exists to remove.
  def change
    add_column :byte_conversations, :primary_at, :datetime

    add_index :byte_conversations, :user_id,
      unique: true,
      where:  "primary_at IS NOT NULL",
      name:   "index_byte_conversations_on_one_primary_per_user"
  end
end
