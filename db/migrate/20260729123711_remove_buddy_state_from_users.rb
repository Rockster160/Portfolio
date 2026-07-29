class RemoveBuddyStateFromUsers < ActiveRecord::Migration[7.1]
  # These now live per-conversation on byte_conversations (backfilled in the
  # preceding migration). buddy_enabled lives on tasks and is untouched.
  def up
    remove_column :users, :buddy_theme
    remove_column :users, :buddy_expression
    remove_column :users, :buddy_sleep_until
  end

  def down
    add_column :users, :buddy_theme, :string, null: false, default: "byte"
    add_column :users, :buddy_expression, :string, null: false, default: "neutral"
    add_column :users, :buddy_sleep_until, :datetime
  end
end
