# == Schema Information
#
# Table name: bowlers
#
#  id           :integer          not null, primary key
#  name         :text
#  position     :integer
#  total_games  :integer
#  total_points :integer
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  league_id    :integer
#

class Bowler < ApplicationRecord
  belongs_to :league, class_name: "BowlingLeague", foreign_key: :league_id
  has_many :games, class_name: "BowlingGame", dependent: :destroy

  def total_games
    # Should be storing this somewhere
    games.count
  end

  def total_points
    # Should be storing this somewhere
    games.sum(:score)
  end

  def average
    return unless total_games&.positive?

    (total_points.to_i / total_games.to_f).round
  end

  def handicap
    league&.handicap_from_average(average)
  end
end
