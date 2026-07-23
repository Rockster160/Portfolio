# == Schema Information
#
# Table name: chores
#
#  id                  :bigint           not null, primary key
#  aliases             :jsonb            not null
#  archived_at         :datetime
#  hot_eligibility     :integer          default("when_available"), not null
#  icon                :text
#  marked_due_at       :datetime
#  name                :text             not null
#  notes               :text
#  notes_template      :text
#  one_off             :boolean          default(FALSE), not null
#  recurrence          :jsonb
#  reward_pebbles      :integer          default(0), not null
#  sharing_mode        :integer          default("personal"), not null
#  short_name          :text
#  show_on_today_view  :integer          default("when_scheduled"), not null
#  sort_order          :integer
#  starts_on           :date
#  target_count        :integer          default(1), not null
#  threshold_seconds   :integer
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  assigned_to_user_id :bigint
#  chore_household_id  :bigint           not null
#  created_by_user_id  :bigint           not null
#  parent_chore_id     :bigint
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
  FREQUENCIES = [:never, :daily, :weekdays, :weekly, :monthly, :yearly, :custom, :relative, :after_chore].freeze
  ANCHOR_CHAIN_MAX_DEPTH = 32
  CUSTOM_UNITS = [:day, :week, :month].freeze
  RELATIVE_UNITS = CUSTOM_UNITS
  # `:after_chore` reuses :day/:week/:month and additionally allows
  # interval 0 (same chore-day) — "Fold Laundry surfaces the moment
  # Laundry is done".
  AFTER_CHORE_UNITS = CUSTOM_UNITS

  # Sentinel values for `threshold_seconds`:
  #   nil / 0           — no cooldown
  #   > 0               — fixed-duration cooldown in seconds
  #   THRESHOLD_DAY_RESET (-1) — cooldown clears at the next ChoreDay
  #                              boundary (4am). Designed to be expandable:
  #                              add new sentinels below 0 if more "calendar"
  #                              cooldowns are needed (week-reset, month-reset).
  THRESHOLD_DAY_RESET = -1

  # show_on_today_view enum — controls when an item appears on the Today
  # tab (Today section if due_today, Scheduled section otherwise). The
  # Dailies section is gated separately by the user's ChoreDaily pin and
  # is unaffected by this field.
  #   :always                       — always shown (even without a schedule)
  #   :when_scheduled (default)     — only on scheduled days (carryover allowed)
  #   :when_available               — whenever cooldown has elapsed
  #   :when_scheduled_and_available — scheduled OR cooldown elapsed (union;
  #                                    named "and" for the button label
  #                                    "Scheduled or Available")
  #   :never                        — never (Grid view only)
  enum :show_on_today_view, {
    always:                       0,
    when_scheduled:               1,
    when_available:               2,
    when_scheduled_and_available: 3,
    never:                        4,
  }, default: :when_scheduled, prefix: :today

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
  # Sub-chores: a SubChore is a Chore with `parent_chore_id` set —
  # everything else inherits Chore's behaviour, but its completions
  # credit the parent (see ChoreCompleter). Single level only:
  # validation below forbids a sub-chore from itself being a parent.
  belongs_to :parent_chore, class_name: "Chore", optional: true
  has_many :sub_chores,
    -> { where(archived_at: nil) },
    class_name: "Chore",
    foreign_key: :parent_chore_id,
    inverse_of: :parent_chore,
    dependent: :destroy
  has_many :chore_completions, dependent: :destroy
  # Completions tapped against this chore acting as a sub-chore — their
  # `chore_id` points at the parent, `sub_chore_id` at this row.
  has_many :sub_chore_completions,
    class_name: "ChoreCompletion",
    foreign_key: :sub_chore_id,
    inverse_of: :sub_chore,
    dependent: :nullify
  has_many :chore_hot_picks, dependent: :destroy
  has_many :chore_streaks, dependent: :destroy
  has_many :chore_dailies, dependent: :destroy

  validates :name, presence: true
  validates :reward_pebbles, numericality: { greater_than_or_equal_to: 0 }
  validates :target_count, numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: 99 }
  validates :threshold_seconds, numericality: { only_integer: true }, allow_nil: true
  validate :threshold_seconds_is_valid_sentinel_or_positive
  validate :anchor_chore_is_valid
  validate :sub_chore_constraints

  # Cascade archive: archiving a parent archives every live sub-chore in
  # one shot so the user doesn't see orphan sub-chores after archive.
  # `update_columns` skips callbacks — sub-chores shouldn't fan out
  # their own :archived Jil triggers as a side effect of the parent's
  # archive — but DOES bump updated_at so /chores/sync picks them up.
  after_update_commit :cascade_archive_to_sub_chores, if: :saved_change_to_archived_at?

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
  scope :sub_chores, -> { where.not(parent_chore_id: nil) }
  scope :top_level, -> { where(parent_chore_id: nil) }
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

  # Convenience predicate — keep callers from sprinkling
  # `parent_chore_id.present?` everywhere.
  def sub_chore? = parent_chore_id.present?

  # User-stamped "this needs to get done" flag. While set, the chore
  # appears on Today (if stamped during the current chore-day) or in
  # the Scheduled/overdue section (if stamped on a prior chore-day).
  # Any ChoreCompletion clears the stamp — see ChoreCompletion's
  # after-create callback.
  def marked_due? = marked_due_at.present?

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

  def after_chore?
    freq == :after_chore
  end

  # The id of the chore this one follows (via :after_chore freq).
  # Stored in the recurrence JSON to avoid a dedicated column for a
  # field that's only meaningful for one freq type.
  def anchor_chore_id
    raw = recurrence_data[:anchor_chore_id]
    Integer(raw, exception: false) if raw.present?
  end

  # Lazy lookup. Use ChoreSerializerContext for bulk paths — this is
  # the fallback for single-record calls (specs, ad-hoc usage).
  def anchor_chore
    @anchor_chore ||= Chore.find_by(id: anchor_chore_id) if anchor_chore_id.present?
  end

  def last_completion_for(user)
    chore_completions.where(user_id: user.id).order(completed_at: :desc).first
  end

  # Visibility for a given calendar `date` and user. Fixed-pattern
  # schedules (daily/weekdays/weekly/monthly/yearly/custom) ignore the
  # user — they fire on their pattern. Relative schedules anchor to
  # `last_completed_day` for that user, falling back to starts_on /
  # created_at so the first appearance still happens.
  def matches_day?(date, user=nil, last_completed_day: :unset, anchor_last_day: :unset)
    return false unless scheduled?
    return false if excluded_dates.include?(date)

    if after_chore?
      return anchor_matches_day?(
        date,
        user,
        b_last_before_today: (last_completed_day == :unset ? nil : last_completed_day),
        anchor_last_day:     anchor_last_day,
      )
    end

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

  # The exact date a relative-scheduled chore becomes due for `user`,
  # anchored to their last completion (or starts_on/created_at when they
  # haven't done it yet). Returns nil for non-relative chores. Lets
  # callers distinguish "strictly due today" from "overdue since some
  # earlier day" — `matches_day?` conflates the two by returning true
  # for any date >= due_on.
  def relative_due_on(user=nil, last_completed_day: :unset)
    return nil unless relative?

    last = effective_last_completed_day(user, last_completed_day)
    if last
      interval, unit = relative_interval_unit
      advance(last, interval, unit)
    else
      starts_on || created_at&.to_date
    end
  end

  def excluded_dates
    Array(recurrence_data[:excluded_dates]).filter_map { |d| safe_date(d) }.to_set
  end

  # Date when an :after_chore follower becomes due, given a particular
  # anchor `last_day` (or nil for "never"). Used by the serializer's
  # `due_today?` to distinguish "newly due today" from "carryover from
  # a prior anchor completion."
  def after_chore_due_on_for(anchor_last_day)
    return nil if anchor_last_day.nil?

    interval, unit = after_chore_offset
    advance(anchor_last_day, interval, unit)
  end

  # Returns the anchor chore's most recent credited completion `day_key`
  # under `user`'s cooldown scope (or nil). Bulk callers should use
  # `ChoreSerializerContext#anchor_last_day_by_chore` instead — this is
  # the per-record fallback.
  def lookup_anchor_last_day(user)
    return nil if anchor_chore_id.blank?
    return nil if user.nil?

    ChoreCompletion.credited
      .where(chore_id: anchor_chore_id, user_id: cooldown_scope_user_ids(user))
      .maximum(:day_key)
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
    return true if last.blank?
    # Anonymous completions have payout_skipped=true but represent real
    # work — they hold the cooldown just like a paid completion.
    # Cooldown-skipped taps (payout_skipped without anonymous) don't
    # gate the next payout; treat as if no relevant completion exists.
    return true if last.payout_skipped && !last.anonymous

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
      target_count:        target_count,
      threshold_seconds:   threshold_seconds,
      sharing_mode:        sharing_mode,
      one_off:             one_off,
      archived:            archived?,
      marked_due_at:       marked_due_at&.iso8601(3),
      created_by_user_id:  created_by_user_id,
      assigned_to_user_id: assigned_to_user_id,
      parent_chore_id:     parent_chore_id,
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
    # Surface the most-specific lifecycle event so listeners can match
    # the exact thing they care about (archive, mark-due, etc.) without
    # filtering every `:updated` event for the column they want.
    # Completion-driven clears use update_columns and skip callbacks,
    # so an `:unmarked_due` event here only fires for explicit user
    # clears (UI button or Jil Chore.unmark_due) — not for a clear that
    # happened because the chore was completed.
    action = (
      if saved_change_to_archived_at? && archived_at.present?
        :archived
      elsif saved_change_to_marked_due_at?
        marked_due_at.present? ? :marked_due : :unmarked_due
      else
        :updated
      end
    )
    ::Jil.trigger(created_by_user, :chore, with_jil_attrs(jil_attrs(action: action)))
  end

  def fire_jil_destroy_trigger
    ::Jil.trigger(created_by_user, :chore, with_jil_attrs(jil_attrs(action: :destroyed)))
  end

  def broadcast_chore_change
    ChoreBroadcaster.broadcast_changes!(created_by_user, self)
  end

  # Sub-chore rules:
  #   * must be a one-off (sub-chores are always single-shot)
  #   * parent cannot itself be a sub-chore (single-level only — chains
  #     would make the credit redirect ambiguous)
  #   * parent must live in the same household (cross-household credit
  #     would silently move pebbles between households)
  #   * cannot point at self
  def sub_chore_constraints
    return if parent_chore_id.blank?

    if parent_chore_id == id
      errors.add(:parent_chore_id, "cannot point at the chore itself")
      return
    end

    parent = parent_chore || Chore.find_by(id: parent_chore_id)
    if parent.nil?
      errors.add(:parent_chore_id, "does not exist")
      return
    end
    errors.add(:parent_chore_id, "cannot itself be a sub-chore")  if parent.parent_chore_id.present?
    errors.add(:parent_chore_id, "cannot be a one-off")            if parent.one_off
    errors.add(:parent_chore_id, "must be in the same household") if parent.chore_household_id != chore_household_id
  end

  def cascade_archive_to_sub_chores
    return unless archived?
    return if parent_chore_id.present? # sub-chores don't have sub-chores

    Chore.where(parent_chore_id: id, archived_at: nil)
      .update_all(archived_at: Time.current, updated_at: Time.current)
  end

  def threshold_seconds_is_valid_sentinel_or_positive
    return if threshold_seconds.nil? || threshold_seconds == THRESHOLD_DAY_RESET
    return if threshold_seconds.positive?

    errors.add(:threshold_seconds, "must be positive or the day-reset sentinel (-1)")
  end

  # Validates an `:after_chore` chore's anchor: must be set, must point
  # at a different chore in the same household, and walking the anchor
  # chain must not cycle back to self.
  def anchor_chore_is_valid
    return unless after_chore?

    aid = anchor_chore_id
    if aid.blank?
      errors.add(:recurrence, "after_chore requires an anchor_chore_id")
      return
    end
    if aid == id
      errors.add(:recurrence, "anchor_chore_id cannot point at the chore itself")
      return
    end

    anchor = Chore.find_by(id: aid)
    if anchor.nil?
      errors.add(:recurrence, "anchor_chore_id does not exist")
      return
    end
    if anchor.chore_household_id != chore_household_id
      errors.add(:recurrence, "anchor_chore must belong to the same household")
      return
    end

    cursor = anchor
    seen = Set.new([id].compact)
    ANCHOR_CHAIN_MAX_DEPTH.times do
      break if cursor.nil?

      if seen.include?(cursor.id)
        errors.add(:recurrence, "anchor_chore_id forms a cycle")
        return
      end

      seen << cursor.id
      next_id = cursor.anchor_chore_id
      break if next_id.blank?

      cursor = Chore.find_by(id: next_id)
    end
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

  # Like `relative_interval_unit`, but allows interval=0 so a chore
  # can surface the moment its anchor is completed (no waiting).
  def after_chore_offset
    interval = [recurrence_data[:interval].to_i, 0].max
    unit = (recurrence_data[:unit].to_s.presence || :day).to_sym
    unit = :day unless AFTER_CHORE_UNITS.include?(unit)
    [interval, unit]
  end

  # The :after_chore predicate. `b_last_before_today` is B's last
  # completed day strictly before `date` (passed in from the serializer
  # so B's own mid-day completion can't drop B from today's Scheduled).
  # `anchor_last_day` is the anchor chore's most-recent credited
  # `day_key` under B's cooldown user scope; the serializer context
  # bulk-loads it. When omitted (:unset) we fall back to a lazy query.
  def anchor_matches_day?(date, user, b_last_before_today:, anchor_last_day: :unset)
    return false if anchor_chore_id.blank?

    a_last_day = anchor_last_day == :unset ? lookup_anchor_last_day(user) : anchor_last_day
    return false if a_last_day.nil?

    interval, unit = after_chore_offset
    due_on = advance(a_last_day, interval, unit)
    return false if date < due_on

    return true if b_last_before_today.nil?

    a_last_day > b_last_before_today
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
