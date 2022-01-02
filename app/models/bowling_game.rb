# == Schema Information
#
# Table name: bowling_games
#
#  id         :integer          not null, primary key
#  card_point :boolean          default(FALSE)
#  frames     :text
#  game_num   :integer
#  game_point :boolean          default(FALSE)
#  handicap   :integer
#  position   :integer
#  score      :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  bowler_id  :integer
#  set_id     :integer
#

class BowlingGame < ApplicationRecord
  attr_accessor :bowler_name, :league_id

  belongs_to :set, class_name: "BowlingSet", inverse_of: :games
  belongs_to :bowler, inverse_of: :games

  after_save { bowler.update(name: bowler_name) if bowler_name.present? && bowler&.name != bowler_name }

  before_validation { self.bowler_id ||= Bowler.create(league_id: set.league_id) }

  def self.points
    where(game_point: true).count + where(card_point: true).count
  end

  def self.total_scores
    sum(:score) + sum(:handicap)
  end

  def league_id
    @new_attributes&.dig(:league_id) || set&.league_id || bowler&.league_id
  end

  def total_score
    score.to_i + handicap.to_i
  end

  def frame_details
    [
      {
        frame: ["9", "/"],
        # pins: ["", ""],
      },
      {
        frame: ["X", "9", "/"],
        pins: [
          [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
          [1, 2, 3, 4, 5, 6, 7, 8, 9],
          [10]
        ],
      },
    ]
  end

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
