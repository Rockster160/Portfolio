class AddRecurrenceToBuddyReminders < ActiveRecord::Migration[7.1]
  def change
    add_column :buddy_reminders, :recurrence,     :jsonb
    add_column :buddy_reminders, :last_fired_at,  :datetime
  end
end
