class AddMergedFieldsToBuddyMemories < ActiveRecord::Migration[7.1]
  def change
    # `kind`, not `type` — `type` is reserved for single-table inheritance and
    # Rails would try to instantiate a class named after every value.
    add_column(:buddy_memories, :kind, :integer, default: 0, null: false)

    # A 0-100 scale rather than an enum. 0 is "keep it, never raise it", 100 is
    # "this is the biggest thing in their life right now". The widened capture
    # rules produce a lot of records at the low end, and a handful of enum
    # buckets can't separate worth-keeping from worth-interrupting-for.
    add_column(:buddy_memories, :severity, :integer, default: 0, null: false)

    add_column(:buddy_memories, :summary, :text)
    add_column(:buddy_memories, :status, :integer, default: 0, null: false)

    # The stash bucket, carried over from buddy_ideas. It is NOT a third
    # taxonomy competing with `kind` and `tags`: `kind` is what sort of record
    # this is, `tags` is how it gets found, and `category` is which pile the
    # person files a stashed thought into — a filing concept they drive by hand
    # ("move that to work"). Tag search matches it too, so retrieval stays a
    # single path.
    add_column(:buddy_memories, :category, :integer)

    # When this becomes worth asking about, which is NOT the same as how much it
    # matters. A parent's surgery next week is severe now and actionable in six
    # days; ordering the queue by severity alone would ask about it tomorrow.
    add_column(:buddy_memories, :relevant_at, :datetime)

    # `checked_in_at` is a LAST-CHECKED stamp, not a terminal seal: an answer
    # ("she's still in hospital, doing okay") re-arms `check_in_at` rather than
    # closing the record. What ends it is `status`, or severity falling to zero.
    add_column(:buddy_memories, :check_in_at, :datetime)
    add_column(:buddy_memories, :checked_in_at, :datetime)

    add_column(:buddy_memories, :surfaced_at, :datetime)
    add_column(:buddy_memories, :last_touched_at, :datetime)

    # Which message this came out of, for the admin UI and for tracing a bad
    # write back to what was actually said.
    add_reference(:buddy_memories, :source_message, foreign_key: { to_table: :byte_messages }, null: true)

    add_index(:buddy_memories, [:user_id, :kind])
    add_index(:buddy_memories, [:user_id, :status])

    # Partial: only a handful of rows ever carry a pending check-in, and the
    # sweep asks for exactly those.
    add_index(:buddy_memories, :check_in_at, where: "check_in_at IS NOT NULL")

    # Tags are the primary recall path now that MEMORY_RECALL_LIMIT is gone, so
    # containment lookups have to be indexed rather than scanned.
    add_index(:buddy_memories, :tags, using: :gin)
  end
end
