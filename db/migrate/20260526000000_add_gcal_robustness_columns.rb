class AddGcalRobustnessColumns < ActiveRecord::Migration[7.1]
  def change
    # All-day events arrive from Google as `start.date` (no time component).
    # Stored here so the UI can render "all day" instead of "12:00am".
    add_column :agenda_items, :all_day, :boolean, default: false, null: false
    add_column :agenda_schedules, :all_day, :boolean, default: false, null: false

    # Cooldown timestamp for events.watch failures. When Google denies push
    # for a calendar (holiday/shared/etc), we record the time and skip
    # subsequent watch attempts until the cooldown elapses.
    add_column :agendas, :watch_failed_at, :datetime

    # Set when the user's OAuth refresh fails (token revoked externally).
    # Drives a UI banner asking the user to reconnect.
    add_column :agendas, :reauth_required_at, :datetime
  end
end
