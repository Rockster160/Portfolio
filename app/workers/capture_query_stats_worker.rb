# Each capture resets pg_stat_statements, so a row holds only what a query cost
# since the previous capture. Rows therefore add up exactly: a day of them
# summed per query is one row that PgHero's range totals read the same as the
# originals. That is what lets old history shrink without losing its trend.
#
# Kept at three resolutions: every capture for FULL_DETAIL, one row per query
# per day until DAILY_DETAIL, one row per query per week after that, forever.
class CaptureQueryStatsWorker
  include Sidekiq::Worker

  sidekiq_options retry: false

  FULL_DETAIL = 90.days
  DAILY_DETAIL = 1.year

  def perform
    PgHero.capture_query_stats
    roll_up
  end

  private

  # Rolls whatever has aged past each window, however long it has been waiting,
  # so a run that never happened is caught up by the next one.
  def roll_up
    now = Time.now.utc
    day_cutoff = (now - FULL_DETAIL).beginning_of_day
    week_cutoff = (now - DAILY_DETAIL).beginning_of_week(:monday)

    PgHero.databases.each_value { |database|
      roll(database.id, :day, from: week_cutoff, to: day_cutoff)
      roll(database.id, :week, from: Time.at(0).utc, to: week_cutoff)
    }
  end

  # A summary row sits exactly on its bucket's start, which a capture never
  # does. A bucket holding any row off its start still has work in it; it is
  # emptied and rewritten as one row per query, its existing summary folded
  # in. A bucket that is already one row per query is never selected, so a run
  # with nothing new to roll writes nothing. One statement, so the delete and
  # the insert land together or not at all.
  def roll(database, unit, from:, to:)
    PgHero::QueryStats.connection.exec_query(
      PgHero::QueryStats.sanitize_sql_array([
        <<~SQL.squish,
          WITH buckets AS (
            SELECT DISTINCT date_trunc(:unit, captured_at) AS bucket
            FROM pghero_query_stats
            WHERE database = :database
              AND captured_at >= :from AND captured_at < :to
              AND captured_at <> date_trunc(:unit, captured_at)
          ), rolled AS (
            DELETE FROM pghero_query_stats
            WHERE database = :database
              AND captured_at >= :from AND captured_at < :to
              AND date_trunc(:unit, captured_at) IN (SELECT bucket FROM buckets)
            RETURNING *
          )
          INSERT INTO pghero_query_stats
            (database, "user", query, query_hash, total_time, calls, captured_at)
          SELECT database, "user", MIN(query), query_hash, SUM(total_time), SUM(calls), bucket
          FROM (SELECT *, date_trunc(:unit, captured_at) AS bucket FROM rolled) aged
          GROUP BY database, "user", query_hash, bucket
        SQL
        { database: database, unit: unit.to_s, from: from, to: to },
      ]),
    )
  end
end
