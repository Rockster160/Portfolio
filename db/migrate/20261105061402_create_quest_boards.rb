# One row per user holding their whole quest board — item definitions,
# schedules, and the recent per-day counts — as the phone last saved it. The
# phone is the source of truth; this is the copy a fresh device starts from.
class CreateQuestBoards < ActiveRecord::Migration[7.1]
  def change
    create_table(:quest_boards) { |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.jsonb :data, null: false, default: {}
      # Bumped on every save, so a device holding an older copy can tell.
      t.integer :rev, null: false, default: 0
      t.timestamps
    }
  end
end
