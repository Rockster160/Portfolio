class AddBuddyColumnsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :buddy_theme,      :string, default: "byte",  null: false
    add_column :users, :buddy_expression, :string, default: "happy", null: false
  end
end
