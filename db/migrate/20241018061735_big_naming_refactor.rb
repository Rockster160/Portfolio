class BigNamingRefactor < ActiveRecord::Migration[7.1]
  def change
    drop_table :jarvis_tasks
    drop_table :jil_usages
    drop_table :cache_shares

    rename_table :jil_tasks, :tasks
    rename_table :jil_scheduled_triggers, :scheduled_triggers
    rename_table :jil_executions, :executions
    rename_table :jarvis_caches, :user_caches
    rename_table :jarvis_pages, :user_dashboards
    rename_table :jil_prompts, :prompts

    remove_column :prompts, :task_id
  end
end
