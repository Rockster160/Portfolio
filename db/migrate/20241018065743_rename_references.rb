class RenameReferences < ActiveRecord::Migration[7.1]
  def change
    rename_column :executions, :jil_task_id, :task_id
  end
end
