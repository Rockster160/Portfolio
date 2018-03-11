class AddScheduleSettings < ActiveRecord::Migration[5.0]
  def change
    add_column :list_items, :schedule_next, :datetime
  end
end
