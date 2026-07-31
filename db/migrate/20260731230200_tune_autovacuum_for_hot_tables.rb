class TuneAutovacuumForHotTables < ActiveRecord::Migration[7.1]
  # The global autovacuum_vacuum_scale_factor of 0.2 means a table is only
  # vacuumed once a fifth of it is dead. That is fine for small tables and
  # useless for large ones: production `executions` had gone from April to
  # August without an autovacuum while carrying 933k dead tuples, which
  # leaves stale visibility maps (no index-only scans) and stale planner
  # statistics.
  #
  # These are the two high-churn tables. Both take constant deletes — one from
  # ExecutionArchiveWorker, one from DropLogTrackersWorker — so a proportional
  # threshold is the wrong shape for them.
  #
  # Storage parameters live on the table and are not captured in schema.rb, so
  # a schema-loaded database won't have them. That's intentional; this is
  # production tuning, not structure.
  SETTINGS = {
    executions:   { vacuum: 0.02, analyze: 0.01 },
    log_trackers: { vacuum: 0.02, analyze: 0.01 },
  }.freeze

  def up
    SETTINGS.each do |table, factors|
      execute(<<~SQL.squish)
        ALTER TABLE #{table} SET (
          autovacuum_vacuum_scale_factor = #{factors[:vacuum]},
          autovacuum_analyze_scale_factor = #{factors[:analyze]}
        )
      SQL
    end
  end

  def down
    SETTINGS.each_key do |table|
      execute(<<~SQL.squish)
        ALTER TABLE #{table} RESET (
          autovacuum_vacuum_scale_factor,
          autovacuum_analyze_scale_factor
        )
      SQL
    end
  end
end
