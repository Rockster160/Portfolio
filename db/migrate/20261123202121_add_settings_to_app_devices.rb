class AddSettingsToAppDevices < ActiveRecord::Migration[7.1]
  def change
    change_table(:app_devices, bulk: true) { |t|
      t.jsonb :permissions, null: false, default: {}
      t.jsonb :sources, null: false, default: {}
      t.jsonb :hot_links, null: false, default: []
    }
  end
end
