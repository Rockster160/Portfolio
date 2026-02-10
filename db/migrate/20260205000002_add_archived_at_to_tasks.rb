class AddArchivedAtToTasks < ActiveRecord::Migration[7.1]
  def change
    add_column :tasks, :archived_at, :datetime
  end
end
