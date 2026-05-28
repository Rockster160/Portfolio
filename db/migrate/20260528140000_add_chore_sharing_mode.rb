class AddChoreSharingMode < ActiveRecord::Migration[7.1]
  def change
    # 0 = personal (default — every user is independent)
    # 1 = household (one completion satisfies everybody; only the doer is paid)
    # 2 = assigned (only the assignee can see/do it)
    add_column :chores, :sharing_mode, :integer, null: false, default: 0
    add_column :chores, :assigned_to_user_id, :bigint
    add_index :chores, :sharing_mode
    add_index :chores, :assigned_to_user_id
    add_foreign_key :chores, :users, column: :assigned_to_user_id
  end
end
