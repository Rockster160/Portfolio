class RemoveCronTasks < ActiveRecord::Migration[7.1]
  def change
    drop_table :cron_tasks
  end
end
