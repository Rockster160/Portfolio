class AddNotifyUserToBuddyWatches < ActiveRecord::Migration[7.1]
  def change
    # When set, the watch delivers to this person's companion instead of the
    # owner's ("whenever I add to our Agenda, let Rocco know"). Null = the
    # ordinary self-directed watch.
    add_reference :buddy_watches, :notify_user, foreign_key: { to_table: :users }
  end
end
