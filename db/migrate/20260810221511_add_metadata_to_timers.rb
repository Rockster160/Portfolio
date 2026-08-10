class AddMetadataToTimers < ActiveRecord::Migration[7.1]
  def change
    add_column(:timers, :metadata, :jsonb, null: false, default: {})
  end
end
