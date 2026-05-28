class DropChoreSharePermission < ActiveRecord::Migration[7.1]
  def change
    remove_column :chore_shares, :permission, :integer, null: false, default: 1
  end
end
