class CleanGuestsWorker
  include Sidekiq::Worker

  # Deleting other people's accounts is not something to retry blindly.
  sidekiq_options retry: 1

  RETENTION = 1.week
  BATCH_SIZE = 1_000
  # Guard against a single nightly run doing unbounded work; leftovers are
  # picked up tomorrow.
  MAX_DELETES = 100_000

  # retention_days lets a backfill drain an accumulated backlog on a shorter
  # window than the nightly run uses.
  def perform(retention_days=nil)
    cutoff = (retention_days ? retention_days.to_f.days : RETENTION).ago
    deleted = 0

    ::User.guest.where(created_at: ..cutoff).select(:id).in_batches(of: BATCH_SIZE) { |batch|
      ids = batch.pluck(:id)
      deletable = ids - occupied_ids(ids)
      next if deletable.empty?

      deleted += delete_batch(deletable)
      break if deleted >= MAX_DELETES
    }

    deleted
  end

  private

  # A guest is deletable only if it owns no records at all. The previous
  # implementation expressed that as a LEFT OUTER JOIN across every
  # association at once — ~50 tables in one statement, well past Postgres's
  # join_collapse_limit, so the planner stopped reordering and ran it as
  # written. It could not finish against a table this size.
  #
  # Same question, asked per batch instead: for a slice of candidate ids, ask
  # each child table which of them it references. Every query is an indexed
  # probe on at most BATCH_SIZE ids, and the list shrinks as owners are found.
  def occupied_ids(ids)
    occupied = []

    child_columns.each do |table, column|
      remaining = ids - occupied
      break if remaining.empty?

      occupied |= owners_in(table, column, remaining)
    end

    occupied
  end

  def owners_in(table, column, ids)
    quoted = ::User.connection.quote_table_name(table)
    quoted_column = ::User.connection.quote_column_name(column)

    ::User.connection.select_values(
      ::User.sanitize_sql_array(
        ["SELECT DISTINCT #{quoted_column} FROM #{quoted} WHERE #{quoted_column} IN (?)", ids],
      ),
    ).map(&:to_i)
  end

  # Associations alone aren't enough: several tables (buddy_memories,
  # buddy_watches, household_icons...) point at users with a real foreign key
  # but no matching has_many. Those constraints are NO ACTION, so missing one
  # doesn't orphan anything — it just aborts the delete — but a batch that
  # keeps failing never drains. Union both sources so the check matches what
  # the database will actually enforce.
  def child_columns
    @child_columns ||= (reflection_columns | foreign_key_columns).sort
  end

  def reflection_columns
    ::User.reflections.values.reject { |reflection|
      reflection.options.key?(:through) || reflection.belongs_to?
    }.filter_map { |reflection| reflection_column(reflection) }
  end

  def reflection_column(reflection)
    [reflection.klass.table_name, reflection.foreign_key.to_s]
  rescue ::NameError
    nil
  end

  def foreign_key_columns
    ::User.connection.select_rows(<<~SQL.squish)
      SELECT c.conrelid::regclass::text, a.attname
      FROM pg_constraint c
      JOIN unnest(c.conkey) AS k(attnum) ON true
      JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
      WHERE c.contype = 'f' AND c.confrelid = 'users'::regclass
    SQL
  end

  # Safe because occupied_ids already proved these rows own nothing, so there
  # is no dependent: :destroy work to do — and skipping instantiation is the
  # difference between minutes and hours at this volume.
  def delete_batch(ids)
    ::User.where(id: ids).delete_all
  rescue ::ActiveRecord::InvalidForeignKey => e
    ::Rails.logger.warn("[CleanGuestsWorker] skipped batch of #{ids.size}: #{e.message}")
    0
  end
end
