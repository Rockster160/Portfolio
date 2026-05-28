class AddChoreVisibility < ActiveRecord::Migration[7.1]
  def change
    add_column :chores, :show_on_daily_view, :integer, null: false, default: 1
    add_index :chores, :show_on_daily_view
  end
end
