class AddMoreTracking < ActiveRecord::Migration[5.0]
  def change
    add_column :log_trackers, :ip_count, :integer

    reversible do |migration|
      migration.up do
        LogTracker.all.each(&:save)
      end
    end
  end
end
