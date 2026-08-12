class AddConditionToScheduledThings < ActiveRecord::Migration[7.1]
  def change
    # A truthy check answered at fire time — see ScheduleCondition. Nullable
    # rather than defaulting to {}, so "has never carried one" and "carried one
    # that was cleared" stay distinguishable from the row alone.
    add_column :buddy_reminders, :condition, :jsonb
    add_column :scheduled_triggers, :condition, :jsonb

    # The intraday half of a repeat: `recurrence.at` is the START, `until_at`
    # stops it for the day and `every_minutes` is the step between. Both live in
    # the existing recurrence jsonb, so nothing new is needed here — this is
    # only the note that the shape grew, since the column won't say so.
  end
end
