# == Schema Information
#
# Table name: bowling_games
#
#  id         :integer          not null, primary key
#  card_point :boolean          default(FALSE)
#  frames     :text
#  game_num   :integer
#  position   :integer
#  score      :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  bowler_id  :integer
#  set_id     :integer
#

class BowlingGame < ApplicationRecord
  belongs_to :set, class_name: "BowlingSet", inverse_of: :games
  belongs_to :bowler

  before_validation { self.bowler ||= Bowler.create(league_id: set.league_id) }

  def frames
    @frames ||= (super.to_s.split("|").presence || Array.new(10)).map { |roll| roll.to_s.split("") }
  end

  def frames=(frames_arr)
    if frames_arr.is_a?(Hash)
      scores = frames_arr.map do |_idx, tosses|
        tosses.join("")
      end.join("|")

      super(scores)
    else
      super(frames_arr)
    end
  end
end
