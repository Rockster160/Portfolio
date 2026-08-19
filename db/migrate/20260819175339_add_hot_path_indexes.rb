class AddHotPathIndexes < ActiveRecord::Migration[7.1]
  def change
    # `ScheduledTrigger.not_scheduled.upcoming_soon` runs every minute from
    # JilScheduleWorker with nothing to stand on, so it swept all 168k rows
    # each time. Partial on `jid IS NULL` because that's the only half the
    # scheduler ever asks about.
    add_index :scheduled_triggers, :execute_at,
      where: "jid IS NULL",
      name:  "index_scheduled_triggers_on_pending_execute_at"

    # Jil's event search filters by user and orders by timestamp. The
    # user_id-only index can't serve the sort, and one user owns 99.6% of the
    # table, so every search sorted all 45k rows.
    add_index :action_events, [:user_id, :timestamp], order: { timestamp: :desc }
  end
end
