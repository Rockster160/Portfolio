class AddCapturedAtIndexToPgheroQueryStats < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  # Every PgHero history page and the rollup in CaptureQueryStatsWorker select by
  # database and a captured_at range. Built CONCURRENTLY so the capture that
  # writes every five minutes is never blocked by it.
  def change
    add_index(
      :pghero_query_stats,
      [:database, :captured_at],
      algorithm: :concurrently,
    )
  end
end
