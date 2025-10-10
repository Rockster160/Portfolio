# == Schema Information
#
# Table name: bowling_leagues
#
#  id                   :integer          not null, primary key
#  absent_calculation   :text             default("AVG - 10")
#  games_per_series     :integer          default(3)
#  hdcp_base            :integer          default(210)
#  hdcp_factor          :float            default(0.95)
#  lanetalk_center_uuid :string
#  name                 :text
#  team_name            :text
#  team_size            :integer          default(4)
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  user_id              :integer
#

class BowlingLeague < ApplicationRecord
  belongs_to :user

  has_many :bowlers, foreign_key: :league_id, dependent: :destroy, inverse_of: :league
  has_many :sets, class_name: "BowlingSet", foreign_key: :league_id, dependent: :destroy, inverse_of: :league
  has_many :bowler_sets, through: :bowlers
  has_many :games, through: :sets
  has_many :frames, through: :games, source: :new_frames

  accepts_nested_attributes_for :bowlers, allow_destroy: true

  def self.create_default(user)
    formatted_date = Time.current.in_time_zone("Mountain Time (US & Canada)").to_fs(:short_day_month)

    create(name: formatted_date, user: user, hdcp_base: "", hdcp_factor: "")
  end

  def roster
    bowlers.ordered.limit([team_size.to_i, 1].max)
  end

  def uses_handicap?
    hdcp_base?
  end

  def factor
    hdcp_factor.presence || 1.to_f
  end

  def temp_calc_new_avg(bowler, new_series)
    new_pins = bowler.total_pins.to_i + new_series.to_i
    new_games = bowler.total_games.to_f + league.games_per_series

    (new_pins / new_games).floor
  end

  def avg_change_over_series(bowler, change)
    new_avg = bowler.average.to_i + change.to_i
    new_avg += 1 unless change.positive? # Offset for flooring

    new_games = bowler.total_games.to_i + games_per_series.to_i
    total_pins_for_change = new_avg * new_games

    # P = A * G
    changed_pins = total_pins_for_change - bowler.total_pins.to_i
    changed_pins -= 1 unless change.positive? # Offset for flooring

    changed_pins
  end

  def handicap_from_average(average)
    return if average.blank? || !uses_handicap?

    ((hdcp_base - average) * factor).floor
  end

  def absent_score(average)
    return if average.blank? || absent_calculation.blank?
    return if absent_calculation.gsub("AVG", "").match?(/[a-z]/i)

    # AVG - 10
    eval(absent_calculation.gsub("AVG", average.to_s)).floor
  end

  def reset_all_scores
    bowler_sets.find_each(&:recalc)
    sets.find_each(&:save_scores)
  end
end
