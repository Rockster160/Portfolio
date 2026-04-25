class ExecutionCompactWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  RETENTION_PER_GROUP = 10
  BATCH_SIZE = 1000

  def perform
    return if User.advisory_lock_exists?(lock_name)

    User.with_advisory_lock(lock_name, 0) {
      loop do
        rows = candidate_rows
        break if rows.empty?

        compact_batch(rows)
        break if rows.length < BATCH_SIZE
      end
    }
  end

  private

  def lock_name
    "execution_compact_worker"
  end

  def candidate_rows
    sql = <<~SQL.squish
      SELECT id, payload_id FROM (
        SELECT id, payload_id,
          ROW_NUMBER() OVER (PARTITION BY user_id, task_id, status ORDER BY started_at DESC) AS rn
        FROM executions
        WHERE payload_id IS NOT NULL
      ) ranked
      WHERE rn > #{RETENTION_PER_GROUP.to_i}
      LIMIT #{BATCH_SIZE.to_i}
    SQL
    ::Execution.connection.select_rows(sql)
  end

  def compact_batch(rows)
    execution_ids = rows.map(&:first)
    payload_ids = rows.map(&:last)

    ::Execution.transaction do
      ::ExecutionPayload.where(id: payload_ids).delete_all
      ::Execution.where(id: execution_ids).update_all(payload_id: nil) # rubocop:disable Rails/SkipsModelValidations
    end
  end
end
