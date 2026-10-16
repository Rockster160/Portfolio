class AddNotStartedPartialIndexToScheduledTriggers < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  # The table keeps every trigger ever fired (hundreds of thousands of rows), but
  # only the handful that haven't started matter to Schedule.search / cancelByTag /
  # the runner, which all scope through `not_started` (started_at IS NULL). The
  # only usable index was on user_id, and one account owns essentially every row,
  # so those queries seq-scanned the whole table — seconds each, growing forever.
  # A partial index over just the not-started rows keeps them instant. Built
  # CONCURRENTLY so adding it never locks the live table.
  def change
    add_index(
      :scheduled_triggers, [:user_id, :trigger],
      where:     "started_at IS NULL",
      name:      "index_scheduled_triggers_on_not_started",
      algorithm: :concurrently
    )
  end
end
