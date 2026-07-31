class ExecutionArchiveWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  # `executions` is append-only usage/billing data that had no retention at
  # all — two years and five million rows deep, with every index on it growing
  # forever. Rather than delete, move anything past the hot window into
  # `execution_archives`, which keeps the same ids and timestamps but carries
  # only two indexes and is never touched by the request path.
  #
  # The Jil dashboard only ever looks back 7 days, so 30 keeps every live view
  # served entirely from the hot table.
  RETENTION = 30.days
  BATCH_SIZE = 5_000
  MAX_BATCHES = 200
  TIME_BUDGET = 10.minutes

  COLUMNS = %w[
    id
    user_id
    task_id
    status
    auth_type
    auth_type_id
    trigger_scope
    started_at
    finished_at
    created_at
  ].freeze

  # retention_days lets a backfill drain the pre-existing history in passes.
  def perform(retention_days=nil)
    return 0 if ::User.advisory_lock_exists?(lock_name)

    cutoff = (retention_days ? retention_days.to_f.days : RETENTION).ago
    archived = 0

    ::User.with_advisory_lock(lock_name, 0) {
      deadline = Time.current + TIME_BUDGET

      MAX_BATCHES.times do
        break if Time.current > deadline

        rows = ::Execution.where(started_at: ..cutoff).limit(BATCH_SIZE).pluck(:id, :payload_id)
        break if rows.empty?

        archived += archive_batch(rows)
      end
    }

    archived
  end

  private

  def lock_name
    "execution_archive_worker"
  end

  # Copy then delete, in one transaction, so a row is never in neither table.
  # The insert is ON CONFLICT DO NOTHING, so a batch that half-applied and got
  # retried re-converges instead of raising on the ids already moved.
  def archive_batch(rows)
    ids = rows.map(&:first)
    payload_ids = rows.filter_map(&:last)

    ::Execution.transaction do
      ::Execution.connection.execute(copy_sql(ids))
      ::Execution.where(id: ids).delete_all
      ::ExecutionPayload.where(id: payload_ids).delete_all if payload_ids.any?
    end

    ids.size
  end

  def copy_sql(ids)
    columns = COLUMNS.join(", ")

    ::Execution.sanitize_sql_array(
      [
        "INSERT INTO execution_archives (#{columns}) " \
        "SELECT #{columns} FROM executions WHERE id IN (?) " \
        "ON CONFLICT (id) DO NOTHING",
        ids,
      ],
    )
  end
end
