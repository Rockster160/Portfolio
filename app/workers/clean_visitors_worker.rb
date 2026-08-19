# Nightly sweep for what people leave behind when they turn up once and never
# come back: a guest account created and never used, an IP that made a single
# request. Both accumulate forever otherwise, and neither is worth keeping.
#
# One worker rather than one per table. They run on the same schedule and have
# the same shape — a retention window, batched deletes, a count returned — and
# the only thing that genuinely differs is how each decides a row was
# abandoned. Adding a third sweep here is a constant and a private method.
class CleanVisitorsWorker
  include Sidekiq::Worker

  # Deleting other people's accounts is not something to retry blindly.
  sidekiq_options retry: 1

  GUEST_RETENTION = 1.week
  GUEST_BATCH_SIZE = 1_000
  # Guard against a single run doing unbounded work. Hitting this is not the
  # end of the sweep — see the resume in #perform.
  MAX_GUEST_DELETES = 100_000
  # Long enough that a capped run isn't hammering the database back to back,
  # short enough that a real backlog drains tonight rather than over weeks.
  RESUME_DELAY = 1.minute

  # Vacuumed after a sweep that actually deleted something. These are the only
  # two tables this worker removes rows from.
  VACUUM_TABLES = %i[users ip_visits].freeze

  # An IP is kept far longer than a guest account, because the count IS the
  # record — it's what tells a regular from a newcomer from a stranger, and
  # that answer has to survive a quiet spell.
  IP_RETENTION = 90.days
  # Strictly one visit. A second request is the signal that this is a real
  # visitor rather than a scanner passing through, and those are kept forever.
  IP_ONE_OFF_VISITS = 1
  IP_BATCH_SIZE = 5_000

  # guest_retention_days lets a backfill drain an accumulated backlog on a
  # shorter window than the nightly run uses. It applies to guests only; the IP
  # sweep is cheap enough that it has never needed draining.
  def perform(guest_retention_days=nil)
    guests = clean_guests(guest_retention_days)
    ip_visits = clean_ip_visits

    if guests >= MAX_GUEST_DELETES
      # The cap was reached, so there is more waiting. Come back for it now
      # rather than leaving the remainder until tomorrow — a backlog that only
      # drains 100k a night never catches up if it grows faster than that.
      # Carries the retention window so a shortened drain stays shortened.
      self.class.perform_in(RESUME_DELAY, guest_retention_days)
    elsif (guests + ip_visits).positive?
      vacuum!
    end

    { guests: guests, ip_visits: ip_visits }
  end

  private

  # Deleting rows in bulk leaves the planner describing a table that no longer
  # exists, and leaves the space unreclaimed until autovacuum gets to it. Doing
  # it here puts that cost next to the deletes that caused it. Only on the
  # final pass — vacuuming between resumed chunks would be wasted work.
  #
  # Plain VACUUM, deliberately NOT VACUUM FULL. Only FULL returns space to the
  # OS, but it takes an ACCESS EXCLUSIVE lock and every request touches
  # `users`, so it would block the whole site. FULL stays a manual operation
  # run at a chosen moment.
  def vacuum!
    connection = ::ActiveRecord::Base.connection
    # VACUUM cannot run inside a transaction block, and callers (specs among
    # them) may well be in one.
    return if connection.transaction_open?

    VACUUM_TABLES.each { |table|
      connection.execute("VACUUM ANALYZE #{connection.quote_table_name(table)}")
    }
  end

  # An IP that made one request three months ago is a stranger, and should read
  # as one if it ever comes back. Forgetting it is the point, not just
  # housekeeping.
  def clean_ip_visits
    scope = ::IpVisit.where(visit_count: ..IP_ONE_OFF_VISITS)
    scope = scope.where(last_seen_at: ..IP_RETENTION.ago)
    scope.in_batches(of: IP_BATCH_SIZE).delete_all
  end

  def clean_guests(retention_days)
    cutoff = (retention_days ? retention_days.to_f.days : GUEST_RETENTION).ago
    deleted = 0

    ::User.guest.where(created_at: ..cutoff).select(:id).in_batches(of: GUEST_BATCH_SIZE) { |batch|
      ids = batch.pluck(:id)
      deletable = ids - occupied_ids(ids)
      next if deletable.empty?

      deleted += delete_batch(deletable)
      break if deleted >= MAX_GUEST_DELETES
    }

    deleted
  end

  # A guest is deletable only if it owns no records at all. The previous
  # implementation expressed that as a LEFT OUTER JOIN across every
  # association at once — ~50 tables in one statement, well past Postgres's
  # join_collapse_limit, so the planner stopped reordering and ran it as
  # written. It could not finish against a table this size.
  #
  # Same question, asked per batch instead: for a slice of candidate ids, ask
  # each child table which of them it references. Every query is an indexed
  # probe on at most GUEST_BATCH_SIZE ids, and the list shrinks as owners are
  # found.
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
    ::Rails.logger.warn("[CleanVisitorsWorker] skipped batch of #{ids.size}: #{e.message}")
    0
  end
end
