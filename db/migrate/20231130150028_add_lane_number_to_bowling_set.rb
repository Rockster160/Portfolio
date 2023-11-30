class AddLaneNumberToBowlingSet < ActiveRecord::Migration[7.0]
  def change
    add_column :bowling_sets, :lane_number, :integer
  end
end
