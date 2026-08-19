class CreateBuddyMemoryNotes < ActiveRecord::Migration[7.1]
  # The thread on a memory. Optional by design: a `concept` ("log means chore")
  # never grows one, a `followup` collects one every time the person gives an
  # update. One table with optional notes rather than a subtype.
  #
  # Replaces buddy_idea_notes, which is left in place until the backfill has run
  # in production (lib/scripts/merge_buddy_ideas_into_memories.rb).
  def change
    create_table(:buddy_memory_notes) { |t|
      t.references(:buddy_memory, null: false, foreign_key: true)
      t.text(:body, null: false)
      t.integer(:source, default: 0, null: false)
      t.timestamps
    }
  end
end
