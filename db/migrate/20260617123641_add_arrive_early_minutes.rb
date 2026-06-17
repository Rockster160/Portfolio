class AddArriveEarlyMinutes < ActiveRecord::Migration[7.1]
  def change
    add_column :agenda_items,     :arrive_early_minutes, :integer, default: 0, null: false
    add_column :agenda_schedules, :arrive_early_minutes, :integer, default: 0, null: false
  end
end
