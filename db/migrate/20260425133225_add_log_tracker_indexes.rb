class AddLogTrackerIndexes < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # Supports DropLogTrackersWorker's `WHERE created_at < ?` and any time-bounded reads.
    add_index :log_trackers, :created_at, algorithm: :concurrently, if_not_exists: true

    # Supports the `set_ip_count` callback's `WHERE ip_address = ?` lookup.
    add_index :log_trackers, :ip_address, algorithm: :concurrently, if_not_exists: true
  end
end
