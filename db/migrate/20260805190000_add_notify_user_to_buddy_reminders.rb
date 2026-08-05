class AddNotifyUserToBuddyReminders < ActiveRecord::Migration[7.1]
  # Who the reminder is FOR, when that isn't the person who set it. Same column
  # and same meaning as buddy_watches.notify_user_id: the row stays owned by the
  # requester (so it's theirs to see and cancel) and delivery goes to the
  # recipient's companion at fire time.
  #
  # "Send a reminder to Chelsea in 10 minutes" had nowhere to put the recipient,
  # so it set an ordinary reminder and pinged the wrong person (prod 2547).
  def change
    add_reference :buddy_reminders, :notify_user, foreign_key: { to_table: :users }, null: true
  end
end
