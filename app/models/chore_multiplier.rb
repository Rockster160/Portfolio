# == Schema Information
#
# Table name: chore_multipliers
#
#  id         :bigint           not null, primary key
#  active     :boolean          default(TRUE), not null
#  config     :jsonb            not null
#  kind       :integer          default("daily_pebble_threshold"), not null
#  name       :string           not null
#  sort_order :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  chore_id   :bigint           not null
#  user_id    :bigint           not null
#
class ChoreMultiplier < ApplicationRecord
  KINDS = {
    daily_pebble_threshold: 0,
    weekly_pebble_threshold: 1,
    daily_streak: 2,
  }.freeze

  enum :kind, KINDS, default: :daily_pebble_threshold

  belongs_to :user
  # Multipliers are always per-chore — there's no "applies to every chore"
  # mode. The multiplier only fires when ITS chore is being completed.
  belongs_to :chore

  validates :name, presence: true

  scope :active, -> { where(active: true) }

  # Returns multiplier (Float >= 1.0) to apply to a new completion right
  # now. Picks the largest level the user has reached.
  #
  # config is expected to look like:
  #   { "levels" => [ { "threshold" => 20, "multiplier" => 1.25 }, ... ] }
  # For :daily_streak the threshold is the current streak days; the
  # caller passes the streak count via `for_streak:`.
  def current_multiplier(user_obj, for_streak: nil)
    levels = Array(config["levels"]).sort_by { |l| l["threshold"].to_i }
    return 1.0 if levels.empty?

    current_value = (
      case kind.to_sym
      when :daily_pebble_threshold
        day = ChoreDay.current(user_obj)
        ChoreCompletion.where(user_id: user_obj.id, day_key: day).sum(:paid_pebbles)
      when :weekly_pebble_threshold
        today = ChoreDay.current(user_obj)
        start = today.beginning_of_week(:sunday)
        ChoreCompletion.where(user_id: user_obj.id, day_key: start..today).sum(:paid_pebbles)
      when :daily_streak
        for_streak.to_i
      end
    )

    picked = 1.0
    levels.each do |lvl|
      picked = lvl["multiplier"].to_f if current_value >= lvl["threshold"].to_i
    end
    picked.zero? ? 1.0 : picked
  end
end
