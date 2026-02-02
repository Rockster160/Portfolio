class AddIndexesToExecutionsForPerformance < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    # Composite index for user_id + started_at (covers the common query pattern)
    add_index :executions, [:user_id, :started_at], order: { started_at: :desc },
      algorithm: :concurrently, if_not_exists: true

    # Composite index for task_id + started_at (covers task-specific queries)
    add_index :executions, [:task_id, :started_at], order: { started_at: :desc },
      algorithm: :concurrently, if_not_exists: true

    # Index on status for filtering
    add_index :executions, :status, algorithm: :concurrently, if_not_exists: true
  end
end
