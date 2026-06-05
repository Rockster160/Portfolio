class AddPinnedToTimerQuickButtons < ActiveRecord::Migration[7.1]
  def change
    add_column :timer_quick_buttons, :pinned, :boolean, null: false, default: true
    add_index :timer_quick_buttons, [:user_id, :pinned, :sort_order]
  end
end
