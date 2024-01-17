class ChangeEventName < ActiveRecord::Migration[7.1]
  def change
    rename_column :action_events, :event_name, :name
  end
end
