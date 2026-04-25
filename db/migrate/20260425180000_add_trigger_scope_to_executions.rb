class AddTriggerScopeToExecutions < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def up
    add_column :executions, :trigger_scope, :string unless column_exists?(:executions, :trigger_scope)
    add_index :executions, :trigger_scope, algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :executions, :trigger_scope, algorithm: :concurrently, if_exists: true
    remove_column :executions, :trigger_scope
  end
end
