# == Schema Information
#
# Table name: agenda_schedules
#
#  id                   :bigint           not null, primary key
#  all_day              :boolean          default(FALSE), not null
#  arrive_early_minutes :integer          default(0), not null
#  color                :string
#  duration_minutes     :integer
#  external_etag        :text
#  external_uid         :text
#  external_updated_at  :datetime
#  kind                 :integer          not null
#  location             :string
#  metadata             :jsonb            not null
#  name                 :string           not null
#  notes                :text
#  occurrence_count     :integer
#  recurrence           :jsonb            not null
#  start_time           :time             not null
#  starts_on            :date             not null
#  trigger_expression   :text
#  until_on             :date
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  agenda_id            :bigint           not null
#
class AgendaSchedule < ApplicationRecord
  include Jilable

  # The `start_time` column is a wall-clock time-of-day, NOT a UTC
  # instant. Opt out of AR's `time_zone_aware_attributes` for it —
  # otherwise AR converts "15:00" → UTC using the current Time.zone
  # (with summer DST applied for write) and back via Jan 1, 2000 (always
  # MST for Denver, no DST) → 1-hour shift on every read during DST.
  # Whatever the writer puts in is what the reader gets out, period.
  self.skip_time_zone_conversion_for_attributes = [:start_time]

  KINDS = [:task, :event, :trigger].freeze
  FREQUENCIES = [:daily, :weekdays, :weekly, :monthly, :yearly, :custom].freeze
  WEEKDAY_KEYS = [:sun, :mon, :tue, :wed, :thu, :fri, :sat].freeze
  CUSTOM_UNITS = [:day, :week, :month].freeze
  # Forward-looking window for materializing upcoming occurrences into
  # real rows. Anything further out stays a phantom — the periodic worker
  # rolls the window forward each tick. Past occurrences keep their
  # materialized row (they're history) — we never destroy them after the
  # fact.
  #
  # The window has to be wide enough that derived ScheduledTriggers (e.g.
  # "fire 5 minutes before this event") get created with a future
  # execute_at: AgendaItem creation fires :agenda_item, which runs the
  # listener task, which calls Global.trigger_for to compute
  # execute_at = start_at + offset. If the item materializes too close to
  # start_at, the derived trigger fires immediately at event-start.
  MATERIALIZE_WINDOW = 30.hours

  enum :kind, { task: 0, event: 1, trigger: 2 }

  # 50-year horizon for resolving occurrence_count → until_on. Plenty for any
  # realistic schedule and bounded so a bad rule can't loop forever.
  OCCURRENCE_SCAN_CAP = 50.years

  before_save :sync_until_on_from_occurrence_count, if: -> { occurrence_count.present? }
  after_save :materialize_upcoming!, if: :saved_change_affecting_materialization?
  after_commit :fire_jil_trigger, on: [:create, :update]

  belongs_to :agenda
  has_many :agenda_items, dependent: :destroy

  validates :name, presence: true
  validates :start_time, presence: true
  validates :starts_on, presence: true
  validates :occurrence_count, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :duration_required_for_event
  validate :freq_valid

  delegate :user, to: :agenda

  # Color cascades from the schedule down to its items; falls back to the
  # parent agenda's color when the schedule doesn't have one set.
  def display_color
    color.presence || agenda.color.presence || Agenda::DEFAULT_COLOR
  end

  # Serialized snapshot of EVERYTHING the edit modal needs to prefill the
  # series view of an item — recurrence rule, start/duration/all-day,
  # content fields, and identity. Emitted as `data-schedule` on rendered
  # items so the JS can hydrate without an extra round-trip. Stays in
  # sync with what `agenda_items_controller#explicit_schedule_params`
  # accepts, so the edit-modal payload round-trips cleanly.
  def serialize_for_edit
    {
      id:                   id,
      kind:                 kind,
      name:                 name,
      freq:                 freq,
      by_day:               Array(recurrence_data[:by_day]),
      by_month_day:         Array(recurrence_data[:by_month_day]).map(&:to_i),
      interval:             recurrence_data[:interval]&.to_i,
      unit:                 recurrence_data[:unit],
      by_set_pos:           recurrence_data[:by_set_pos]&.to_i,
      starts_on:            starts_on&.iso8601,
      until_on:             until_on&.iso8601,
      occurrence_count:     occurrence_count,
      start_time:           start_time&.strftime("%H:%M"),
      duration_minutes:     duration_minutes,
      all_day:              all_day,
      color:                color,
      location:             location,
      arrive_early_minutes: arrive_early_minutes,
      notes:                notes,
      trigger_expression:   trigger_expression,
      metadata:             metadata,
    }.compact
  end

  # Schedules whose effective window overlaps [from..to]: started by `to` AND
  # not ended before `from`.
  scope :active_between, ->(from, to) {
    where(starts_on: ..to.to_date).where("until_on IS NULL OR until_on >= ?", from.to_date)
  }

  def freq
    (recurrence_data[:freq].to_s.presence || :daily).to_sym
  end

  def recurrence_data
    (recurrence || {}).with_indifferent_access
  end

  # Not memoized: reload() doesn't clear non-AR ivars, so a stale @set
  # would survive a refresh-from-DB. The set is small enough that
  # recomputing on every call is fine.
  def excluded_dates
    Array(recurrence_data[:excluded_dates]).filter_map { |d| safe_parse_date(d) }.to_set
  end

  def add_excluded_date!(date)
    next_set = excluded_dates + [date.to_date]
    update!(recurrence: recurrence_data.merge(excluded_dates: next_set.map(&:to_s)).to_h)
  end

  def remove_excluded_date!(date)
    next_set = excluded_dates - [date.to_date]
    update!(recurrence: recurrence_data.merge(excluded_dates: next_set.map(&:to_s)).to_h)
  end

  def excluded?(date)
    excluded_dates.include?(date.to_date)
  end

  # Safe wrapper for one-off use: returns nil if the date doesn't match, is
  # excluded, or already has a materialized row. Issues ONE query to check for
  # an existing row — don't call this inside a date-range loop; use Agenda's
  # bulk items_for_range path instead (which does set-based deduping).
  def phantom_for(date)
    return nil unless matches?(date)
    return nil if agenda_items.exists?(start_at: agenda.send(:day_range, date))

    build_phantom(date)
  end

  # Build an in-memory phantom AgendaItem for the given date. Caller is responsible
  # for confirming `matches?(date)` and that no real row already covers that date —
  # see Agenda#items_for_range for the bulk-safe usage.
  # Carries the schedule's `all_day` flag onto the phantom so the renderer
  # (and the edit modal's data attributes) treat it the same as a
  # materialized all-day row.
  def build_phantom(date)
    AgendaItem.new(
      agenda:               agenda,
      agenda_schedule:      self,
      kind:                 kind,
      start_at:             occurrence_start_at(date),
      end_at:               occurrence_end_at(date),
      all_day:              all_day,
      name:                 name,
      notes:                notes,
      location:             location,
      arrive_early_minutes: arrive_early_minutes,
      color:                color,
      trigger_expression:   trigger_expression,
      metadata:             metadata,
    ).tap { |item| item.phantom = true }
  end

  # Pure in-memory check. Never hits the DB.
  def matches?(date)
    return false if until_on.present? && date > until_on

    matches_recurrence_rule?(date)
  end

  # Recurrence-rule match WITHOUT the until_on bound. Used by
  # sync_until_on_from_occurrence_count to walk the rule without recursing
  # through until_on (which we're about to derive).
  def matches_recurrence_rule?(date)
    return false if date < starts_on
    return false if excluded_dates.include?(date)

    case freq
    when :daily    then true
    when :weekdays then (1..5).cover?(date.wday)
    when :weekly   then weekday_indices.include?(date.wday)
    when :monthly  then matches_month_day?(date)
    when :yearly   then date.month == starts_on.month && date.day == starts_on.day
    when :custom   then matches_custom?(date)
    end
  end

  # When the user picks "stop after N occurrences", we resolve that to a
  # concrete `until_on` date at save time so all subsequent matches checks
  # are simple date comparisons rather than walks of the rule.
  def sync_until_on_from_occurrence_count
    return if occurrence_count.blank? || occurrence_count.to_i <= 0

    remaining = occurrence_count.to_i
    date = starts_on
    cap = starts_on + OCCURRENCE_SCAN_CAP
    last_match = nil

    while date <= cap && remaining.positive?
      if matches_recurrence_rule?(date)
        last_match = date
        remaining -= 1
      end
      date += 1
    end

    self.until_on = last_match
  end

  def regenerate_future!
    agenda_items
      .where(start_at: Time.current.beginning_of_day..)
      .where(detached_at: nil)
      .destroy_all
  end

  # The wall-clock time-of-day a given occurrence lands on, materialized in
  # the user's timezone. `start_time` is the single source of truth across
  # every write path (user edits via the series modal stamp it directly,
  # Google sync rewrites it from the master DTSTART on every pull), so
  # phantoms always render at the column's value. Materialized rows carry
  # their own per-instance `start_at` and are not affected.
  def occurrence_start_at(date)
    user_zone.local(date.year, date.month, date.day, start_time.hour, start_time.min)
  end

  def occurrence_end_at(date)
    return nil unless event?
    return nil if duration_minutes.blank?

    occurrence_start_at(date) + duration_minutes.minutes
  end

  # Materialize occurrences (all kinds — task, event, trigger) whose
  # start_at falls inside the next MATERIALIZE_WINDOW. Past occurrences
  # are kept as history; anything further out stays phantom until it
  # rolls into the window. Callers: (1) the after_save hook below, when a
  # schedule's rule/start changes, (2) JilScheduleWorker on its periodic
  # tick. Events get end_at + all_day from the schedule; tasks/triggers
  # leave end_at nil.
  def materialize_upcoming!(through: MATERIALIZE_WINDOW.from_now)
    now = Time.current
    from_date = now.in_time_zone(user.timezone).to_date
    to_date = through.in_time_zone(user.timezone).to_date

    existing_starts = agenda_items
      .where(start_at: now..through)
      .pluck(:start_at)
      .to_set

    (from_date..to_date).each do |date|
      next unless matches?(date)

      occurrence_start = occurrence_start_at(date)
      next if occurrence_start < now || occurrence_start > through
      next if existing_starts.include?(occurrence_start)

      agenda_items.create!(
        agenda:               agenda,
        kind:                 kind,
        name:                 name,
        start_at:             occurrence_start,
        end_at:               occurrence_end_at(date),
        all_day:              all_day,
        color:                color,
        notes:                notes,
        location:             location,
        arrive_early_minutes: arrive_early_minutes,
        trigger_expression:   trigger_expression,
      )
    end
  end

  private

  # Mirrors AgendaItem#fire_jil_trigger so user tasks listening on
  # `:agenda_schedule` can react to lifecycle changes. The metadata-only
  # short-circuit keeps Jil-side metadata writes (travel-time caching)
  # from refiring the schedule task.
  def fire_jil_trigger
    return if Thread.current[::GoogleCalendar::Sync::SUPPRESS_KEY]
    return if metadata_only_change?

    action = saved_change_to_id? ? :created : :updated
    ::Jil.trigger(user, :agenda_schedule, with_jil_attrs(action: action))
  end

  # See AgendaItem#metadata_only_change? — same rationale: skip refire on
  # no-op commits and on Jil-side metadata-only writes.
  def metadata_only_change?
    return true if saved_changes.empty?

    (saved_changes.keys - ["metadata", "updated_at"]).empty? && saved_change_to_metadata?
  end

  def saved_change_affecting_materialization?
    saved_change_to_starts_on? || saved_change_to_until_on? ||
      saved_change_to_recurrence? || saved_change_to_start_time? ||
      saved_change_to_kind? || saved_change_to_name? ||
      saved_change_to_trigger_expression? ||
      saved_change_to_duration_minutes? || saved_change_to_all_day? ||
      previously_new_record?
  end

  def safe_parse_date(value)
    Date.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  def user_zone
    ActiveSupport::TimeZone[user.timezone] || Time.zone
  end

  def weekday_indices
    Array(recurrence_data[:by_day]).filter_map { |d|
      WEEKDAY_KEYS.index(d.to_s.downcase.to_sym)
    }.presence || [starts_on.wday]
  end

  def month_days
    Array(recurrence_data[:by_month_day]).map(&:to_i).presence || [starts_on.day]
  end

  def matches_month_day?(date)
    # Monthly + Nth weekday — e.g. "third Tuesday of every month". When
    # the recurrence carries both `by_set_pos` and `by_day` we ignore
    # `by_month_day` entirely and dispatch to the nth-weekday matcher.
    if recurrence_data[:by_set_pos].present? && recurrence_data[:by_day].present?
      return matches_nth_weekday_of_month?(date)
    end

    month_days.include?(date.day) || (month_days.include?(-1) && date.day == date.end_of_month.day)
  end

  def matches_custom?(date)
    interval = [recurrence_data[:interval].to_i, 1].max
    unit = (recurrence_data[:unit].to_s.presence || :day).to_sym
    unit = :day unless CUSTOM_UNITS.include?(unit)

    case unit
    when :day   then ((date - starts_on).to_i % interval).zero?
    when :week  then (((date - starts_on).to_i / 7) % interval).zero? && date.wday == starts_on.wday
    when :month then matches_custom_month?(date, interval)
    end
  end

  def matches_custom_month?(date, interval)
    return false unless (months_between(starts_on, date) % interval).zero?

    if recurrence_data[:by_set_pos].present? && recurrence_data[:by_day].present?
      matches_nth_weekday_of_month?(date)
    elsif Array(recurrence_data[:by_month_day]).any?
      matches_month_day?(date)
    else
      date.day == starts_on.day
    end
  end

  # Matches "Nth weekday of month" rules: second Thursday, last Friday, etc.
  # set_pos is 1..4 or -1 (last); by_day is a single weekday key.
  def matches_nth_weekday_of_month?(date)
    set_pos = recurrence_data[:by_set_pos].to_i
    target_key = Array(recurrence_data[:by_day]).first
    target_wday = WEEKDAY_KEYS.index(target_key.to_s.downcase.to_sym)
    return false if target_wday.nil? || date.wday != target_wday

    if set_pos == -1
      (date + 7).month != date.month
    else
      week_of_month = ((date.day - 1) / 7) + 1
      week_of_month == set_pos
    end
  end

  def months_between(a, b)
    ((b.year - a.year) * 12) + (b.month - a.month)
  end

  def duration_required_for_event
    return unless event?

    errors.add(:duration_minutes, "is required for events") if duration_minutes.blank? || duration_minutes <= 0
  end

  def freq_valid
    return if recurrence_data[:freq].blank?

    errors.add(:recurrence, "freq must be one of #{FREQUENCIES.join(", ")}") if FREQUENCIES.exclude?(freq)
  end
end
