# == Schema Information
#
# Table name: bowling_sets
#
#  id         :integer          not null, primary key
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  league_id  :integer
#

class BowlingSet < ApplicationRecord
  belongs_to :league, class_name: "BowlingLeague"

  has_many :games, class_name: "BowlingGame", foreign_key: :set_id, inverse_of: :set, dependent: :destroy

  accepts_nested_attributes_for :games

  def complete?
    games_complete >= league.games_per_series
  end

  def games_complete
    return 0 if games.none?

    games.maximum(:game_num).to_i
  end

  def games_for_display(game_num=nil)
    game_num ||= games.maximum(:game_num) || 1
    games_by_num = games.where(game_num: game_num)

    return games_by_num unless games_by_num.none?
    return [BowlingGame.new(game_num: game_num)] if league.nil?

    league.bowlers.order(:position).map.with_index { |bowler, idx|
      bowler.games.new(set_id: id, position: idx, game_num: game_num)
    }
  end
end
