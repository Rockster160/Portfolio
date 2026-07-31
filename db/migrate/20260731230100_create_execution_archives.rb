class CreateExecutionArchives < ActiveRecord::Migration[7.1]
  # Cold storage for executions past the hot window. Executions are usage and
  # billing records, so nothing here is disposable — this moves rows off the
  # write-hot table rather than deleting them, keeping every timestamp intact
  # so usage-over-time reporting stays exact.
  #
  # The payload columns (code/ctx/input_data) are deliberately not carried
  # over: ExecutionCompactWorker has already discarded them long before a row
  # is old enough to archive.
  def change
    # `default: nil` leaves the primary key without a sequence: ids come from
    # the executions row being archived, never generated here. An accidental
    # bare create then fails loudly instead of minting an id that could later
    # collide with a real execution.
    create_table :execution_archives, id: :bigint, default: nil do |t|
      t.bigint :user_id
      t.bigint :task_id
      t.integer :status
      t.integer :auth_type
      t.integer :auth_type_id
      t.string :trigger_scope
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :created_at, null: false

      t.index [:user_id, :started_at], order: { started_at: :desc }
      t.index [:task_id, :started_at], order: { started_at: :desc }
    end
  end
end
