class CreateIpVisits < ActiveRecord::Migration[7.1]
  def change
    create_table(:ip_visits) { |t|
      t.string(:ip_address, null: false)
      t.integer(:visit_count, null: false, default: 0)
      t.datetime(:first_seen_at)
      t.datetime(:last_seen_at)
      t.timestamps
    }

    # The upsert conflict target — every request looks the row up by IP.
    add_index(:ip_visits, :ip_address, unique: true)
    # Serves CleanIpVisitsWorker's "single visit, long gone" sweep.
    add_index(:ip_visits, [:visit_count, :last_seen_at])
  end
end
