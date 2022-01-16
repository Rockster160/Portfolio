# == Schema Information
#
# Table name: bowling_sets
#
#  id         :integer          not null, primary key
#  winner     :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  league_id  :integer
#

class BowlingSet < ApplicationRecord
  belongs_to :league, class_name: "BowlingLeague", touch: true

  has_many :games,
    class_name: "BowlingGame",
    foreign_key: :set_id,
    inverse_of: :set,
    dependent: :destroy
  has_many :bowlers, through: :games

  accepts_nested_attributes_for :games

  def save_scores
    # Establish average for new bowlers
    bowlers.where(total_games: 0).find_each do |bowler|
      bowler.recalculate_scores

      bowler.games.find_each do |game|
        game.update(handicap: bowler.handicap)
      end
    end

    # Now, with updated handicaps, find the high bowler for each game.
    games.group_by(&:game_num).each do |pos, grouped_games|
      high_score = grouped_games.map { |game| game.total_score }.max
      # Ties count as a point for each
      grouped_games.each { |game| game.update(game_point: true) if game.total_score == high_score }
    end

    # Find the bowler who won the total pins
    totals = games.group_by(&:bowler_id).map do |bowler_id, grouped_games|
      [bowler_id, grouped_games.sum(&:total_score)]
    end
    high_total = totals.map(&:last).max
    found_winner_ids = totals.select { |id_score| id_score.last == high_total }
    update(winner: ",#{found_winner_ids.map(&:first).join(",")},")

    bowlers.distinct.each(&:recalculate_scores)
  end

  def winner?(bowler)
    winner&.include?(",#{bowler.id},")
  end

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
    previous_games = games.where(game_num: game_num.to_i - 1)

    return games_by_num unless games_by_num.none?
    return [BowlingGame.new(game_num: game_num)] if league.nil?

    (bowlers.presence || league.bowlers).active.distinct.map.with_index { |bowler, idx|
      bowler.games.new(
        set_id:       id,
        position:     idx,
        game_num:     game_num,
        handicap:     bowler.handicap,
        absent:       !!previous_games.find_by(bowler_id: bowler.id)&.absent,
        absent_score: bowler.absent_score,
      )
    }
  end
end
