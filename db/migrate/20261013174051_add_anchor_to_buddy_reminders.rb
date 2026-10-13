class AddAnchorToBuddyReminders < ActiveRecord::Migration[7.1]
  def change
    add_column :buddy_reminders, :anchor, :text
  end
end
