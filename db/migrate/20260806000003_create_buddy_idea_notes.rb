class CreateBuddyIdeaNotes < ActiveRecord::Migration[7.1]
  # An idea you can come back to.
  #
  # A BuddyIdea has been one immutable `body` since it was added — whatever the
  # person said the moment they said it — plus a `summary` the companion could
  # overwrite. That is the right shape for a loose end and the wrong shape for a
  # thought, because a thought gets added to. Someone tosses up a seed, comes
  # back a week later with a bit more, comes back again with a bit more, and
  # until now the second and third visits had nowhere to land: re-saying it
  # deduped onto the original row (stash_idea matches on lowercased body) and
  # the new detail was simply dropped.
  #
  # So: notes are append-only, the seed stays put, and the whole accumulation is
  # what "yeah, I remember the shape of this" reads back from.
  #
  # `last_touched_at` is separate from `updated_at` because updated_at moves for
  # bookkeeping — a summary rewrite, a category change — and the question being
  # asked of this column is "when did the PERSON last put something into this",
  # which is what decides whether a thread is growing or has gone quiet.
  def change
    create_table :buddy_idea_notes do |t|
      t.belongs_to :buddy_idea, index: true, null: false
      t.text :body, null: false
      # Who added it. A companion-written note (a summary of a conversation
      # where the idea got sharper) is worth keeping but should never be read
      # back as though the person said it.
      t.integer :source, default: 0, null: false

      t.timestamps
    end

    add_column :buddy_ideas, :last_touched_at, :datetime

    reversible { |dir|
      dir.up {
        # Everything that exists was last touched when it was made — there was
        # no other way to touch it.
        execute("UPDATE buddy_ideas SET last_touched_at = created_at WHERE last_touched_at IS NULL")
      }
    }

    add_index :buddy_ideas, :last_touched_at
  end
end
