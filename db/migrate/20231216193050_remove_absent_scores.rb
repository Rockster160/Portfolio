class RemoveAbsentScores < ActiveRecord::Migration[7.0]
  def up
    BowlingGame.where(absent: true).find_each do |game|
      game.update(frames: nil, frame_details: nil)
      game.new_frames.destroy_all
    end
  end
end
