class AddBuddySleepUntilToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :buddy_sleep_until, :datetime
  end
end
