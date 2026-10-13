class AllowAnchoredRemindersWithoutAFireTime < ActiveRecord::Migration[7.1]
  def change
    change_column_null :buddy_reminders, :fire_at, true
  end
end
