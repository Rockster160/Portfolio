class AddChurnTrackingToUserPushSubscriptions < ActiveRecord::Migration[7.1]
  def change
    add_column :user_push_subscriptions, :endpoint_changes, :integer, default: 0, null: false
    add_column :user_push_subscriptions, :retired_at, :datetime
  end
end
