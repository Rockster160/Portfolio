# == Schema Information
#
# Table name: bowling_leagues
#
#  id                   :integer          not null, primary key
#  absent_calculation   :text             default("AVG - 10")
#  games_per_series     :integer          default(3)
#  handicap_calculation :text             default("(210 - AVG) * 0.95")
#  name                 :text
#  team_name            :text
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  user_id              :integer
#

class BowlingLeague < ApplicationRecord
  belongs_to :user

  has_many :bowlers, foreign_key: :league_id, dependent: :destroy, inverse_of: :league
  has_many :sets, class_name: "BowlingSet", foreign_key: :league_id, dependent: :destroy, inverse_of: :league
  has_many :games, through: :sets

  accepts_nested_attributes_for :bowlers

  def self.create_default(user)
    formatted_date = Time.current.to_formatted_s(:short_day_month)

    create(name: formatted_date, user: user)
  end

  def handicap_from_average(average)
    return if average.blank?
    return if handicap_calculation.gsub("AVG", "").match?(/[a-z]/i)
    # (210 - AVG) * 0.95
    eval(handicap_calculation.gsub("AVG", average.to_s)).floor
  end

  def absent_score(average)
    return if average.blank?
    return if absent_calculation.gsub("AVG", "").match?(/[a-z]/i)
    # AVG - 10
    eval(absent_calculation.gsub("AVG", average.to_s)).floor
  end
end
