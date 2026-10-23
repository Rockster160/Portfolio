class AddMetadataToBackgroundProcesses < ActiveRecord::Migration[7.1]
  def change
    add_column :background_processes, :metadata, :jsonb, null: false, default: {}
  end
end
