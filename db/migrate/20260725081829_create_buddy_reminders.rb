class CreateBuddyReminders < ActiveRecord::Migration[7.1]
  def change
    create_table :buddy_reminders do |t|
      t.references :user,              null: false, foreign_key: true
      t.references :byte_conversation, null: false, foreign_key: true
      t.string     :kind,              null: false, default: "reminder"
      t.text       :body,              null: false
      t.datetime   :fire_at,           null: false
      t.datetime   :fired_at
      t.datetime   :cancelled_at
      t.jsonb      :metadata,          null: false, default: {}
      t.timestamps
    end
    # BuddyReminderWorker sweeps every minute for anything past fire_at
    # and not fired/cancelled. Filtered index keeps that sweep cheap
    # even when the table has years of history.
    add_index :buddy_reminders,
      :fire_at,
      where: "fired_at IS NULL AND cancelled_at IS NULL",
      name:  "idx_buddy_reminders_pending"
  end
end
