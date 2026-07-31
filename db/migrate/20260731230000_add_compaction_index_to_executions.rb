class AddCompactionIndexToExecutions < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  # ExecutionCompactWorker ranks rows with
  #   ROW_NUMBER() OVER (PARTITION BY user_id, task_id, status ORDER BY started_at DESC)
  #   WHERE payload_id IS NOT NULL
  # every minute. With no index on payload_id that meant a full scan plus sort
  # of the whole table to reach the handful of uncompacted rows — a few
  # thousand out of millions. Matching the index to the window frame lets the
  # planner walk only the rows that still have a payload, presorted.
  #
  # Partial, so the index covers only uncompacted rows and shrinks as the
  # worker drains it.
  def up
    add_index :executions, [:user_id, :task_id, :status, :started_at],
      order:         { started_at: :desc },
      where:         "payload_id IS NOT NULL",
      name:          "index_executions_on_compaction_candidates",
      algorithm:     :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :executions, name: "index_executions_on_compaction_candidates",
      algorithm: :concurrently, if_exists: true
  end
end
