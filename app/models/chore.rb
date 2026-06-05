# == Schema Information
#
# Table name: chores
#
#  id                  :bigint           not null, primary key
#  aliases             :jsonb            not null
#  archived_at         :datetime
#  hot_eligibility     :integer          default("when_available"), not null
#  icon                :text
#  name                :text             not null
#  notes_template      :text
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
#  chore_household_id  :bigint           not null
#  created_by_user_id  :bigint           not null
#
class Chore < ApplicationRecord
  include Jilable, Orderable

  orderable_by(sort_order: :asc)
  orderable_scope ->(chore) { Chore.where(chore_household_id: chore.chore_household_id) }

  # Lifecycle triggers — fan out to Jil so user-written tasks can react
  # to chore creation, edits, and archival. Listeners use the standard
  # Tokenizing syntax against the trigger data, e.g.
  #   `chore action:archived name:Vitamins`.
  # ChoreCompletion fires its own `chore_completion` triggers separately
  # (one per tap / undo) so completion-focused tasks don't have to wade
  # through every chore edit.
  after_create_commit  :fire_jil_create_trigger
  after_update_commit  :fire_jil_update_trigger
  after_destroy_commit :fire_jil_destroy_trigger
  before_validation :default_chore_household_from_creator, on: :create
  # Every persisted change fans out a Monitor broadcast so every open
  # client refreshes — Jil-created chores, console scripts, and the
  # controller path all reach the same fanout without each call site
  # having to remember it.
  after_commit :broadcast_chore_change, on: [:create, :update, :destroy]

  WEEKDAY_KEYS = AgendaSchedule::WEEKDAY_KEYS
  FREQUENCIES = [:never, :daily, :weekdays, :weekly, :monthly, :yearly, :custom, :relative].freeze
  CUSTOM_UNITS = [:day, :week, :month].freeze
  RELATIVE_UNITS = CUSTOM_UNITS

  # Sentinel values for `threshold_seconds`:
  #   nil / 0           — no cooldown
  #   > 0               — fixed-duration cooldown in seconds
  #   THRESHOLD_DAY_RESET (-1) — cooldown clears at the next ChoreDay
  #                              boundary (4am). Designed to be expandable:
  #                              add new sentinels below 0 if more "calendar"
  #                              cooldowns are needed (week-reset, month-reset).
  THRESHOLD_DAY_RESET = -1

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

  # Cooldown scope:
  #   :personal   — every user's cooldown is their own
  #   :household  — one paid tap puts the whole household on cooldown
  enum :sharing_mode, {
    personal:  0,
    household: 1,
  }, default: :personal, prefix: :share

  # Whether this chore can become a Hot Pick:
  #   :when_available — eligible whenever the worker's normal rules permit
  #                     (current behaviour: unscheduled, due-today, or overdue)
  #   :when_scheduled — only eligible on a day it's actually scheduled / overdue
  #                     (i.e. unscheduled chores never become Hot Picks)
  #   :never          — never eligible, no matter what
  enum :hot_eligibility, {
    when_available: 0,
    when_scheduled: 1,
    never:          2,
  }, default: :when_available, prefix: :hot

  belongs_to :chore_household
  belongs_to :created_by_user, class_name: "User"
  belongs_to :assigned_to_user, class_name: "User", optional: true
  has_many :chore_completions, dependent: :destroy
  has_many :chore_hot_picks, dependent: :destroy
  has_many :chore_streaks, dependent: :destroy
  has_many :chore_dailies, dependent: :destroy

  validates :name, presence: true
  validates :reward_pebbles, numericality: { greater_than_or_equal_to: 0 }
  validates :threshold_seconds, numericality: { only_integer: true }, allow_nil: true
  validate :threshold_seconds_is_valid_sentinel_or_positive

  def assigned? = assigned_to_user_id.present?

  # Grid visibility for a user. Assignment is a separate dimension from
  # sharing mode:
  #   personal  + assigned    — only the assignee can see at all
  #   household + assigned    — everyone can see (on Grid); Today is
  #                             filtered to the assignee elsewhere
  #   personal/household + no assignee — everyone in the share group sees it
  def visible_to?(user)
    return true unless assigned?
    return true if share_household?

    assigned_to_user_id == user.id
  end

  # Whose cooldown timer fires for this chore:
  #   :household — every user in the chore's household
  #   :personal/:assigned — just the viewing user
  def cooldown_scope_user_ids(viewer)
    return [viewer.id] unless share_household?

    User.where(chore_household_id: chore_household_id).pluck(:id)
  end

  scope :active, -> { where(archived_at: nil) }
  scope :recurring, -> { where("recurrence IS NOT NULL AND recurrence != '{}'::jsonb") }
  scope :one_offs, -> { where(one_off: true) }
  scope :persistent, -> { where(one_off: false) }
  # Assignment narrows visibility only when the chore's cooldown is
  # personal. household-cooldown chores stay grid-visible to every
  # household member; the Today gate runs in the serializer.
  scope :visible_to_user, ->(user_id) {
    where(
      "assigned_to_user_id IS NULL OR sharing_mode = ? OR assigned_to_user_id = ?",
      sharing_modes[:household], user_id
    )
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

  def cooldown_until_day_reset?
    threshold_seconds == THRESHOLD_DAY_RESET
  end

  # Has the cooldown for `user` elapsed (i.e. the next tap would pay)?
  # `last_completion` is accepted as an arg to avoid per-row queries
  # when iterating many chores — the today controller bulk-loads them.
  def cooldown_elapsed?(user, last_completion: :unset, now: Time.current)
    return true if threshold_seconds.to_i.zero?

    last = last_completion == :unset ? last_completion_for(user) : last_completion
    return true if last.blank? || last.payout_skipped

    if cooldown_until_day_reset?
      # Elapsed once we've crossed the ChoreDay boundary (4am).
      # Comparing day_keys is exact, so users see the cooldown end
      # at the same moment the Today view rolls over.
      return last.day_key != ChoreDay.current(user)
    end

    (last.completed_at + threshold_seconds.seconds) <= now
  end

  # The chore's "what would a Jil listener want?" payload. Mirrors
  # AgendaItem / ActionEvent / Task — a single hash flattening the
  # common fields plus an `action` discriminator the listener can
  # filter on (`chore action:archived`, `chore action:created`).
  def jil_attrs(action:)
    {
      id:                  id,
      action:              action,
      name:                name,
      short_name:          display_short_name,
      icon:                icon,
      reward_pebbles:      reward_pebbles,
      threshold_seconds:   threshold_seconds,
      sharing_mode:        sharing_mode,
      one_off:             one_off,
      archived:            archived?,
      created_by_user_id:  created_by_user_id,
      assigned_to_user_id: assigned_to_user_id,
    }
  end

  private

  def default_chore_household_from_creator
    return if chore_household_id.present?
    return if created_by_user.nil?

    # Fall back to a direct membership lookup when the cached
    # users.chore_household_id is stale (e.g. mid-test after a
    # membership row was created on this same user object).
    self.chore_household_id = created_by_user.chore_household_id ||
      ChoreHouseholdMembership.where(user_id: created_by_user_id).pick(:chore_household_id)
  end

  def fire_jil_create_trigger
    ::Jil.trigger(created_by_user, :chore, with_jil_attrs(jil_attrs(action: :created)))
  end

  def fire_jil_update_trigger
    # Archive (soft delete) is signalled by `archived_at` flipping from
    # nil → set. Surface it as a distinct action so listeners can react
    # to archive separately from any other update.
    action = saved_change_to_archived_at? && archived_at.present? ? :archived : :updated
    ::Jil.trigger(created_by_user, :chore, with_jil_attrs(jil_attrs(action: action)))
  end

  def fire_jil_destroy_trigger
    ::Jil.trigger(created_by_user, :chore, with_jil_attrs(jil_attrs(action: :destroyed)))
  end

  def broadcast_chore_change
    ChoreBroadcaster.broadcast_changes!(created_by_user, self)
  end

  def threshold_seconds_is_valid_sentinel_or_positive
    return if threshold_seconds.nil? || threshold_seconds == THRESHOLD_DAY_RESET
    return if threshold_seconds.positive?

    errors.add(:threshold_seconds, "must be positive or the day-reset sentinel (-1)")
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
