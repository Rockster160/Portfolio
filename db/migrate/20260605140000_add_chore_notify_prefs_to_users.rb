class AddChoreNotifyPrefsToUsers < ActiveRecord::Migration[7.1]
  def change
    # Per-event opt-out toggles for the Chores push channel. Empty hash
    # defaults to "all on" — see User#wants_chore_notification?.
    add_column :users, :chore_notify_prefs, :jsonb, null: false, default: {}
  end
end
