class DropLegacyExecutionColumns < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    remove_index :executions, name: "index_executions_on_status",
      algorithm: :concurrently, if_exists: true
    remove_index :executions, name: "index_executions_on_task_id",
      algorithm: :concurrently, if_exists: true
    remove_index :executions, name: "index_executions_on_user_id",
      algorithm: :concurrently, if_exists: true

    change_table :executions, bulk: true do |t|
      t.remove :code
      t.remove :ctx
      t.remove :input_data
    end
  end

  def down
    change_table :executions, bulk: true do |t|
      t.text :code
      t.jsonb :ctx
      t.jsonb :input_data
    end

    add_index :executions, :status, algorithm: :concurrently, if_not_exists: true
    add_index :executions, :task_id, algorithm: :concurrently, if_not_exists: true
    add_index :executions, :user_id, algorithm: :concurrently, if_not_exists: true
  end
end
