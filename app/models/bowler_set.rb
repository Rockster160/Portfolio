# == Schema Information
#
# Table name: bowler_sets
#
#  id           :integer          not null, primary key
#  absent_score :integer
#  ending_avg   :integer
#  handicap     :integer
#  starting_avg :integer
#  this_avg     :integer
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  bowler_id    :integer
#  set_id       :integer
#

class BowlerSet < ApplicationRecord
  belongs_to :bowler
  belongs_to :set, class_name: "BowlingSet", inverse_of: :bowler_sets

  delegate :league, to: :set

  def games
    set.games.where(bowler: bowler)
  end

  def recalc
    update(
      absent_score: calc_absent_score,
      handicap:     calc_handicap,
      starting_avg: starting_average,
      ending_avg:   ending_average,
      this_avg:     games.average(:score)&.floor,
    )
  end

  def avg_diff
    return "N/A" if ending_avg.nil? || starting_avg.nil?
    diff = ending_avg - starting_avg

    if diff.positive?
      "+#{diff}"
    else
      diff.to_s
    end
  end

  def game_count
    @game_count ||= bowler.games_at_time(set.created_at)
  end

  def pin_count
    @pin_count ||= bowler.pins_at_time(set.created_at)
  end

  def starting_average
    @average ||= begin
      return unless game_count&.positive?

      (pin_count.to_i / game_count.to_f).floor
    end
  end

  def ending_average
    @ending_average ||= begin
      ending_games = bowler.games_at_time(set.games.maximum(:created_at) + 1.second)
      ending_pins = bowler.pins_at_time(set.games.maximum(:created_at) + 1.second)
      return unless ending_games&.positive?

      (pin_count.to_i / ending_games.to_f).floor
    end
  end

  def calc_handicap
    @handicap ||= begin
      league&.handicap_from_average(starting_average)
    end
  end

  def calc_absent_score
    @absent_score ||= begin
      league&.absent_score(starting_average)
    end
  end
end
