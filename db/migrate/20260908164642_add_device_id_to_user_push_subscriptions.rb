class AddDeviceIdToUserPushSubscriptions < ActiveRecord::Migration[7.1]
  def change
    add_column :user_push_subscriptions, :device_id, :string
    add_index :user_push_subscriptions, [:user_id, :channel, :device_id]
  end
end
