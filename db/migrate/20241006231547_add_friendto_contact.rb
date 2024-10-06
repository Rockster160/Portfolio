class AddFriendtoContact < ActiveRecord::Migration[7.1]
  def change
    add_reference :contacts, :friend
    add_column :contacts, :permit_relay, :boolean, default: true
  end
end
