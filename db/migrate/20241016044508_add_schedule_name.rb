class AddScheduleName < ActiveRecord::Migration[7.1]
  def change
    add_column :jil_scheduled_triggers, :name, :text
  end
end
