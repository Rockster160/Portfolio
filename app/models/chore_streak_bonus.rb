# == Schema Information
#
# Table name: chore_streak_bonuses
#
#  id         :bigint           not null, primary key
#  active     :boolean          default(TRUE), not null
#  config     :jsonb            not null
#  kind       :integer          default("chore_streak"), not null
#  name       :string           not null
#  sort_order :integer
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  chore_id   :bigint
#  user_id    :bigint           not null
#
class ChoreStreakBonus < ApplicationRecord
  # Rails' default inflector pluralizes "bonus" → "bonus" (treats it as
  # already plural since `-us` ends look like Latin plurals). Pin the
  # table name explicitly so we don't depend on inflection edge cases.
  self.table_name = "chore_streak_bonuses"

  KINDS = {
    chore_streak:   0,
    daily_pebbles:  1,
    weekly_pebbles: 2,
  }.freeze

  enum :kind, KINDS, default: :chore_streak

  # Human-facing labels — used in the modal kind dropdown, the bonus
  # card subtitle, and anywhere else the user sees a kind name. The
  # internal symbol stays for code; this is the surface text.
  KIND_LABELS = {
    chore_streak:   "Streak on a chore",
    daily_pebbles:  "Pebbles earned today",
    weekly_pebbles: "Pebbles earned this week",
  }.freeze

  def kind_label
    KIND_LABELS[kind.to_sym] || kind.to_s.humanize
  end

  belongs_to :user
  belongs_to :chore, optional: true

  validates :name, presence: true
  validate :chore_required_for_chore_specific_kinds
  validate :levels_are_integer_multipliers

  scope :active, -> { where(active: true) }

  # Bonuses that could fire for `chore_id`:
  #   * chore_streak rows matching that chore_id
  #   * daily/weekly pebble rows (chore_id IS NULL — they fire on any
  #     chore completion)
  scope :applicable_to, ->(chore_id) {
    where("chore_id = ? OR chore_id IS NULL", chore_id)
  }

  def chore_specific?
    kind.to_sym == :chore_streak
  end

  # Returns the highest-threshold level the user has crossed, or nil.
  def current_level(user_obj, for_streak: nil)
    levels = sorted_levels
    return nil if levels.empty?

    value = current_threshold_value(user_obj, for_streak: for_streak)
    levels.reverse_each.find { |lvl| value >= lvl["threshold"].to_i }
  end

  def current_multiplier(user_obj, for_streak: nil)
    raw = (current_level(user_obj, for_streak: for_streak) || {})["multiplier"].to_i
    raw.zero? ? 1 : raw
  end

  def current_bonus(user_obj, for_streak: nil)
    (current_level(user_obj, for_streak: for_streak) || {})["bonus_pebbles"].to_i
  end

  def sorted_levels
    Array(config["levels"]).sort_by { |l| l["threshold"].to_i }
  end

  private

  def current_threshold_value(user_obj, for_streak: nil)
    case kind.to_sym
    when :chore_streak
      for_streak.to_i
    when :daily_pebbles
      day = ChoreDay.current(user_obj)
      ChoreCompletion.where(user_id: user_obj.id, day_key: day).sum(:paid_pebbles)
    when :weekly_pebbles
      today = ChoreDay.current(user_obj)
      start = today.beginning_of_week(:sunday)
      ChoreCompletion.where(user_id: user_obj.id, day_key: start..today).sum(:paid_pebbles)
    end
  end

  def chore_required_for_chore_specific_kinds
    return unless chore_specific?
    return if chore_id.present?

    errors.add(:chore_id, "is required for chore-streak bonuses")
  end

  def levels_are_integer_multipliers
    Array(config["levels"]).each do |lvl|
      next if lvl["multiplier"].blank?

      m = lvl["multiplier"]
      next if m.is_a?(Integer)
      next if m.is_a?(Float) && m == m.to_i
      next if m.is_a?(String) && m.match?(/\A\d+\z/)

      errors.add(:config, "multipliers must be whole numbers (got #{m.inspect})")
      return
    end
  end
end
