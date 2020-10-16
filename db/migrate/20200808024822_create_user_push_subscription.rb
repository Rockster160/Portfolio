class CreateUserPushSubscription < ActiveRecord::Migration[5.0]
  def change
    create_table :user_push_subscriptions do |t|
      t.belongs_to :user
      t.string :sub_auth
      t.string :endpoint
      t.string :p256dh
      t.string :auth

      t.timestamps
    end
  end
end
