class AddTimestampToClimbs < ActiveRecord::Migration[7.0]
  def change
    add_column :climbs, :timestamp, :datetime, default: -> { "CURRENT_TIMESTAMP" }
  end
end
