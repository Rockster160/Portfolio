# == Schema Information
#
# Table name: bowlers
#
#  id                 :integer          not null, primary key
#  high_game          :integer
#  high_series        :integer
#  name               :text
#  position           :integer
#  total_games        :integer
#  total_games_offset :integer
#  total_pins         :integer
#  total_pins_offset  :integer
#  total_points       :integer
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  league_id          :integer
#

class Bowler < ApplicationRecord
  belongs_to :league, class_name: "BowlingLeague", foreign_key: :league_id, inverse_of: :bowlers
  has_many :games, class_name: "BowlingGame", dependent: :destroy, inverse_of: :bowler

  def recalculate_scores
    update(
      total_games: total_games_offset.to_i + games.count,
      total_pins: total_pins_offset.to_i + games.sum(:score),
      total_points: games.points + winning_sets.count,
      high_game: games.maximum(:score),
      high_series: games.group_by(&:set_id).map { |setid, games| games.sum(&:score) }.max,
    )
  end

  def winning_sets
    BowlingSet.where("bowling_sets.winner LIKE '%,?,%'", id)
  end

  def average
    return unless total_games&.positive?

    (total_pins.to_i / total_games.to_f).floor
  end

  def handicap
    league&.handicap_from_average(average)
  end
end
