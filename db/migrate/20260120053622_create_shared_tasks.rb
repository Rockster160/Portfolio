class CreateSharedTasks < ActiveRecord::Migration[7.1]
  def change
    create_table :shared_tasks do |t|
      t.references :task, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end
    add_index :shared_tasks, [:task_id, :user_id], unique: true
  end
end
