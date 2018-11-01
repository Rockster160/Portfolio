class AddHeadersToLogTracker < ActiveRecord::Migration[5.0]
  def change
    add_column :log_trackers, :headers, :text
  end
end
