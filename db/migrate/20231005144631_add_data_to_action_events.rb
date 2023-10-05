class AddDataToActionEvents < ActiveRecord::Migration[7.0]
  def change
    add_column :action_events, :data, :jsonb
  end
end
