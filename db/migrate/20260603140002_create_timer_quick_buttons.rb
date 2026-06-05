class CreateTimerQuickButtons < ActiveRecord::Migration[7.1]
  def change
    create_table :timer_quick_buttons do |t|
      t.references :user, null: false, foreign_key: true
      t.text    :label
      t.integer :duration_seconds, null: false
      t.integer :sort_order, null: false, default: 0
      t.text    :color
      t.timestamps precision: 6
    end

    add_index :timer_quick_buttons, [:user_id, :sort_order]
  end
end
