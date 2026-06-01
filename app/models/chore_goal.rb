# == Schema Information
#
# Table name: chore_goals
#
#  id              :bigint           not null, primary key
#  achieved_at     :datetime
#  archived_at     :datetime
#  awarded_pebbles :integer          default(0), not null
#  baseline_value  :integer          default(0), not null
#  config          :jsonb            not null
#  description     :text
#  image_url       :text
#  kind            :integer          default("pebbles"), not null
#  link_url        :text
#  name            :string           not null
#  scope_mode      :integer          default("relative"), not null
#  sort_order      :integer
#  target_value    :integer          default(0), not null
#  tracking_mode   :integer          default("earned"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  chore_id        :bigint
#  user_id         :bigint           not null
#
class ChoreGoal < ApplicationRecord
  include Orderable

  orderable_by(sort_order: :asc)
  orderable_scope ->(goal) { ChoreGoal.where(user_id: goal.user_id) }

  belongs_to :user
  belongs_to :chore, optional: true

  KINDS = {
    pebbles:           0,
    total_completions: 1,
    chore_completions: 2,
    chore_streak:      3,
  }.freeze

  SCOPE_MODES = {
    relative:   0,
    cumulative: 1,
  }.freeze

  TRACKING_MODES = {
    earned: 0,
    saved:  1,
  }.freeze

  enum :kind,          KINDS,          default: :pebbles
  enum :scope_mode,    SCOPE_MODES,    default: :relative
  enum :tracking_mode, TRACKING_MODES, default: :earned

  validates :name, presence: true
  validates :target_value, numericality: { greater_than: 0 }
  validate  :chore_id_present_for_chore_specific_kinds

  before_create :snapshot_baseline

  scope :active,      -> { where(archived_at: nil) }
  scope :outstanding, -> { active.where(achieved_at: nil) }
  scope :achieved,    -> { where.not(achieved_at: nil) }

  CHORE_SPECIFIC_KINDS = %i[chore_completions chore_streak].freeze

  def chore_specific?
    CHORE_SPECIFIC_KINDS.include?(kind.to_sym)
  end

  # Whether `tracking_mode` is actually meaningful for this goal's
  # kind — only the pebble kind reads withdrawals.
  def tracking_mode_applies?
    kind.to_sym == :pebbles
  end

  def current_value
    compute_current_value
  end

  def progress_percent
    return 100 if target_value.to_i.zero?

    ((current_value.to_i * 100.0) / target_value).floor.clamp(0, 100)
  end

  def reached?
    current_value.to_i >= target_value.to_i
  end

  # Single entry point for "after a balance/completion change, has this
  # goal newly been earned?". Idempotent: re-running on an
  # already-achieved goal is a no-op.
  def refresh!
    return false if achieved_at.present?
    return false if archived_at.present?
    return false unless reached?

    update!(achieved_at: Time.current)
    true
  end

  # Refresh every outstanding goal for a user. Called after any event
  # that could push a goal across its target (chore completion,
  # withdrawal, transfer). Returns the goals that newly achieved on
  # this pass so callers can broadcast / flash.
  def self.refresh_all_for(user)
    outstanding.where(user_id: user.id).select(&:refresh!)
  end

  # Human-readable "5p / 100p" or "3 / 10 days" — tailored per kind so
  # the same card template can show every goal type cleanly.
  def progress_label
    case kind.to_sym
    when :pebbles            then "#{current_value}p / #{target_value}p"
    when :total_completions  then "#{current_value} / #{target_value} done"
    when :chore_completions  then "#{current_value} / #{target_value}"
    when :chore_streak       then "#{current_value} / #{target_value} days"
    end
  end

  # Short factual subtitle for the card — names what the goal is
  # measuring, nothing more.
  def kind_label
    case kind.to_sym
    when :pebbles
      tracking_mode.to_sym == :saved ? "Pebbles saved" : "Pebbles earned"
    when :total_completions
      "Total completions"
    when :chore_completions
      "#{chore&.name || 'Chore'} completions"
    when :chore_streak
      "#{chore&.name || 'Chore'} streak (days)"
    end
  end

  private

  def compute_current_value
    case kind.to_sym
    when :chore_streak then streak_progress
    else
      raw = raw_total_value
      scope_mode.to_sym == :relative ? [raw - baseline_value.to_i, 0].max : raw
    end
  end

  # Cumulative measure for the user — lifetime values; the relative
  # scope subtracts `baseline_value` (snapshotted at create) outside
  # this method.
  def raw_total_value
    case kind.to_sym
    when :pebbles
      if tracking_mode.to_sym == :saved
        user.chore_balance.to_i
      else
        ChoreCompletion.where(user_id: user.id).sum(:paid_pebbles).to_i
      end
    when :total_completions
      ChoreCompletion.where(user_id: user.id).count
    when :chore_completions
      ChoreCompletion.where(user_id: user.id, chore_id: chore_id).count
    end
  end

  # Streak goals don't fit the "subtract a baseline" model — a streak
  # restart resets the count to 1 regardless of any prior value. We
  # instead compare the streak's STARTING day to the goal's created_at:
  #   cumulative — current_streak OR longest_streak (whichever wins)
  #   relative   — only streaks that started on/after created_at count
  def streak_progress
    streak = ChoreStreak.find_by(user_id: user.id, chore_id: chore_id)
    return 0 unless streak

    current = streak.current_streak.to_i
    if scope_mode.to_sym == :cumulative
      [current, streak.longest_streak.to_i].max
    else
      return 0 if current.zero? || streak.last_completed_day.blank?

      streak_start = streak.last_completed_day - (current - 1)
      streak_start >= created_at.to_date ? current : 0
    end
  end

  def snapshot_baseline
    return unless scope_mode.to_sym == :relative
    return if kind.to_sym == :chore_streak # streak uses date-compare, not baseline subtraction

    self.baseline_value = raw_total_value
  end

  def chore_id_present_for_chore_specific_kinds
    return unless chore_specific?
    return if chore_id.present?

    errors.add(:base, "Chore is required for #{kind.to_s.humanize} goals")
  end
end
