class AddBodyToLogTracker < ActiveRecord::Migration[5.0]
  def change
    add_column :log_trackers, :body, :text
  end
end
