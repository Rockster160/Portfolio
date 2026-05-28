# == Schema Information
#
# Table name: chores
#
#  id                  :bigint           not null, primary key
#  aliases             :jsonb            not null
#  archived_at         :datetime
#  icon                :text
#  name                :text             not null
#  one_off             :boolean          default(FALSE), not null
#  recurrence          :jsonb
#  reward_pebbles      :integer          default(0), not null
#  sharing_mode        :integer          default("personal"), not null
#  short_name          :text
#  show_on_daily_view  :integer          default("when_scheduled"), not null
#  sort_order          :integer
#  starts_on           :date
#  threshold_seconds   :integer
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  assigned_to_user_id :bigint
#  created_by_user_id  :bigint           not null
#
class Chore < ApplicationRecord
  include Orderable

  orderable_by(sort_order: :asc)
  orderable_scope ->(chore) { Chore.where(created_by_user_id: chore.created_by_user_id) }

  WEEKDAY_KEYS = AgendaSchedule::WEEKDAY_KEYS
  FREQUENCIES = [:never, :daily, :weekdays, :weekly, :monthly, :yearly, :custom, :relative].freeze
  CUSTOM_UNITS = [:day, :week, :month].freeze
  RELATIVE_UNITS = CUSTOM_UNITS

  # show_on_daily_view enum — controls when an item appears on Today.
  #   :always                       — always shown (even without a schedule)
  #   :when_scheduled (default)     — only on scheduled days (carryover allowed)
  #   :when_available               — whenever cooldown has elapsed
  #   :when_scheduled_and_available — both scheduled AND cooldown elapsed
  #   :never                        — never (Grid view only)
  enum :show_on_daily_view, {
    always:                       0,
    when_scheduled:               1,
    when_available:               2,
    when_scheduled_and_available: 3,
    never:                        4,
  }, default: :when_scheduled, prefix: :daily

  # Sharing mode — see migration comment for full semantics.
  #   :personal   — every user is independent (default; current behavior)
  #   :household  — one completion satisfies everybody; only the doer is paid
  #   :assigned   — only the assignee sees / can complete
  enum :sharing_mode, {
    personal:  0,
    household: 1,
    assigned:  2,
  }, default: :personal, prefix: :share

  belongs_to :created_by_user, class_name: "User"
  belongs_to :assigned_to_user, class_name: "User", optional: true
  has_many :chore_completions, dependent: :destroy
  has_many :chore_hot_picks, dependent: :destroy
  has_many :chore_streaks, dependent: :destroy

  validates :name, presence: true
  validates :reward_pebbles, numericality: { greater_than_or_equal_to: 0 }
  validates :threshold_seconds, numericality: { greater_than: 0 }, allow_nil: true
  validates :assigned_to_user_id, presence: true, if: :share_assigned?
  before_validation :clear_assignment_unless_assigned

  # Users who can see + complete this chore, given a "share group"
  # (typically `user.chore_owner_user_ids` for the viewing user).
  #   :personal   — every share-group member
  #   :household  — every share-group member
  #   :assigned   — only the assignee
  def visible_to?(user)
    return true if share_assigned? && assigned_to_user_id == user.id
    return false if share_assigned?

    true
  end

  # For shared chores (household/personal/assigned), the "effective"
  # user the cooldown + last-completion checks should look at.
  #   :household — every user in the creator's household closure (both
  #                directions of ChoreShare) so a single bulk query
  #                covers everyone who can see this chore
  #   :personal/:assigned — just the viewing user
  def cooldown_scope_user_ids(viewer)
    return [viewer.id] unless share_household?

    self.class.household_user_ids_for(created_by_user_id)
  end

  # Transitive household closure: every user reachable from `user_id`
  # by walking ChoreShare rows in either direction. A↔B + B↔C means A,
  # B, C are all one household — a user only ever belongs to one. BFS
  # by frontier so we issue one query per hop (typically 1-2 total).
  def self.household_user_ids_for(user_id)
    visited = Set.new
    frontier = Set[user_id]
    until frontier.empty?
      visited.merge(frontier)
      pairs = ChoreShare
        .where("user_id IN (:f) OR shared_with_user_id IN (:f)", f: frontier.to_a)
        .pluck(:user_id, :shared_with_user_id)
      frontier = Set.new(pairs.flatten) - visited
    end
    visited.to_a
  end

  scope :active, -> { where(archived_at: nil) }
  scope :recurring, -> { where("recurrence IS NOT NULL AND recurrence != '{}'::jsonb") }
  scope :one_offs, -> { where(one_off: true) }
  scope :persistent, -> { where(one_off: false) }
  # Visible to a user: everything that isn't `:assigned`, plus chores
  # specifically assigned to them. Personal vs household are both
  # visible to all share-group members.
  scope :visible_to_user, ->(user_id) {
    where("sharing_mode != ? OR assigned_to_user_id = ?", sharing_modes[:assigned], user_id)
  }

  def archived? = archived_at.present?

  def aliases_array
    Array(aliases).map(&:to_s)
  end

  def display_short_name
    short_name.presence || name
  end

  def reward_label
    "#{reward_pebbles}p"
  end

  def recurrence_data
    (recurrence || {}).with_indifferent_access
  end

  def freq
    (recurrence_data[:freq].to_s.presence || :never).to_sym
  end

  def scheduled?
    freq != :never
  end

  def relative?
    freq == :relative
  end

  def last_completion_for(user)
    chore_completions.where(user_id: user.id).order(completed_at: :desc).first
  end

  # Visibility for a given calendar `date` and user. Fixed-pattern
  # schedules (daily/weekdays/weekly/monthly/yearly/custom) ignore the
  # user — they fire on their pattern. Relative schedules anchor to
  # `last_completed_day` for that user, falling back to starts_on /
  # created_at so the first appearance still happens.
  def matches_day?(date, user=nil, last_completed_day: :unset)
    return false unless scheduled?
    return false if excluded_dates.include?(date)

    if relative?
      last = effective_last_completed_day(user, last_completed_day)
      if last
        interval, unit = relative_interval_unit
        due_on = advance(last, interval, unit)
        return date >= due_on
      else
        first = starts_on || created_at&.to_date
        return first.present? && date >= first
      end
    end

    return false if starts_on && date < starts_on

    case freq
    when :daily    then true
    when :weekdays then (1..5).cover?(date.wday)
    when :weekly   then weekday_indices.include?(date.wday)
    when :monthly  then matches_month_day?(date)
    when :yearly   then starts_on && date.month == starts_on.month && date.day == starts_on.day
    when :custom   then matches_custom?(date)
    else false
    end
  end

  def upcoming_days(from: Date.current, days: 7, user: nil)
    (from..(from + days)).select { |d| matches_day?(d, user) }
  end

  def excluded_dates
    Array(recurrence_data[:excluded_dates]).filter_map { |d| safe_date(d) }.to_set
  end

  # Has the cooldown for `user` elapsed (i.e. the next tap would pay)?
  # `last_completion` is accepted as an arg to avoid per-row queries
  # when iterating many chores — the today controller bulk-loads them.
  def cooldown_elapsed?(user, last_completion: :unset, now: Time.current)
    return true if threshold_seconds.to_i.zero?

    last = last_completion == :unset ? last_completion_for(user) : last_completion
    return true if last.blank? || last.payout_skipped

    (last.completed_at + threshold_seconds.seconds) <= now
  end

  private

  def clear_assignment_unless_assigned
    self.assigned_to_user_id = nil unless share_assigned?
  end

  def effective_last_completed_day(user, last_completed_day)
    return last_completed_day unless last_completed_day == :unset
    return nil if user.nil?

    chore_completions.where(user_id: user.id).maximum(:day_key)
  end

  def relative_interval_unit
    interval = [recurrence_data[:interval].to_i, 1].max
    unit = (recurrence_data[:unit].to_s.presence || :day).to_sym
    unit = :day unless RELATIVE_UNITS.include?(unit)
    [interval, unit]
  end

  def advance(date, interval, unit)
    case unit
    when :day   then date + interval
    when :week  then date + (interval * 7)
    when :month then date >> interval
    end
  end

  def safe_date(value)
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def weekday_indices
    Array(recurrence_data[:by_day]).filter_map { |d|
      WEEKDAY_KEYS.index(d.to_s.downcase.to_sym)
    }
  end

  def month_days
    Array(recurrence_data[:by_month_day]).map(&:to_i)
  end

  def matches_month_day?(date)
    # Nth-weekday-of-month: "second Tuesday" → by_set_pos: 2 + by_day: ["tue"],
    # "last Friday" → by_set_pos: -1 + by_day: ["fri"].
    if recurrence_data[:by_set_pos].present? && recurrence_data[:by_day].present?
      matches_nth_weekday_of_month?(date)
    else
      month_days.include?(date.day) ||
        (month_days.include?(-1) && date.day == date.end_of_month.day)
    end
  end

  def matches_nth_weekday_of_month?(date)
    set_pos = recurrence_data[:by_set_pos].to_i
    target_key = Array(recurrence_data[:by_day]).first
    target_wday = WEEKDAY_KEYS.index(target_key.to_s.downcase.to_sym)
    return false if target_wday.nil? || date.wday != target_wday

    if set_pos == -1
      (date + 7).month != date.month
    else
      ((date.day - 1) / 7) + 1 == set_pos
    end
  end

  def matches_custom?(date)
    return false if starts_on.blank?

    interval = [recurrence_data[:interval].to_i, 1].max
    unit = (recurrence_data[:unit].to_s.presence || :day).to_sym
    unit = :day unless CUSTOM_UNITS.include?(unit)

    case unit
    when :day   then ((date - starts_on).to_i % interval).zero?
    when :week  then (((date - starts_on).to_i / 7) % interval).zero? && date.wday == starts_on.wday
    when :month then ((((date.year * 12) + date.month) - ((starts_on.year * 12) + starts_on.month)) % interval).zero? && date.day == starts_on.day
    end
  end
end
