class CreateBackgroundProcesses < ActiveRecord::Migration[7.1]
  def change
    create_table(:background_processes) { |t|
      t.references :user, null: false, foreign_key: true

      # The caller's own name for the work, and the only thing that decides
      # whether a report is a new process or a step in one already running.
      # Every endpoint is an upsert on it, so a script that cannot remember
      # what it created can still update and clear what it left behind.
      t.string :key, null: false
      t.string :name, null: false
      t.integer :state, null: false, default: 0
      t.string :detail
      t.integer :current
      t.integer :total
      # Where a tap should go, as [{label:, url:}] - more than one, because a
      # single link means picking between the job and the queue it came out of
      # and being wrong for somebody.
      t.jsonb :links, null: false, default: []
      t.string :icon
      t.string :source

      t.datetime :started_at, null: false
      # Always stamped, even by a report that changes nothing else, because a
      # caller saying "still here" is the whole signal and `updated_at` does
      # not move for a no-op save.
      t.datetime :heartbeat_at, null: false
      t.datetime :finished_at

      t.timestamps
    }

    # One live process per key, enforced by the database rather than by whoever
    # wrote the caller. Finished rows stay as history and fall outside it.
    add_index :background_processes, [:user_id, :key],
      unique: true, where: "finished_at IS NULL", name: :index_background_processes_live_key
    add_index :background_processes, [:user_id, :heartbeat_at]
  end
end
