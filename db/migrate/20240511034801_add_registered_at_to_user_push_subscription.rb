class AddRegisteredAtToUserPushSubscription < ActiveRecord::Migration[7.1]
  def change
    add_column :user_push_subscriptions, :registered_at, :timestamp

    UserPushSubscription.destroy_all
  end
end
