class AddStrikePointToBowlingFrame < ActiveRecord::Migration[5.0]
  def change
    add_column :bowling_frames, :strike_point, :integer
  end
end
