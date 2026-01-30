class AddChannelToUserPushSubscriptions < ActiveRecord::Migration[7.1]
  def change
    add_column :user_push_subscriptions, :channel, :string, default: "jarvis", null: false
    add_index :user_push_subscriptions, [:user_id, :channel]
  end
end
