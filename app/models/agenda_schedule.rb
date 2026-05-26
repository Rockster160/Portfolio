# == Schema Information
#
# Table name: agenda_schedules
#
#  id                  :bigint           not null, primary key
#  all_day             :boolean          default(FALSE), not null
#  color               :string
#  duration_minutes    :integer
#  external_etag       :text
#  external_uid        :text
#  external_updated_at :datetime
#  kind                :integer          not null
#  location            :string
#  name                :string           not null
#  notes               :text
#  occurrence_count    :integer
#  recurrence          :jsonb            not null
#  start_time          :time             not null
#  starts_on           :date             not null
#  trigger_expression  :text
#  until_on            :date
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  agenda_id           :bigint           not null
#
class AgendaSchedule < ApplicationRecord
  include Jilable

  KINDS = [:task, :event, :trigger].freeze
  FREQUENCIES = [:daily, :weekdays, :weekly, :monthly, :yearly, :custom].freeze
  WEEKDAY_KEYS = [:sun, :mon, :tue, :wed, :thu, :fri, :sat].freeze
  CUSTOM_UNITS = [:day, :week, :month].freeze
  TRIGGER_MATERIALIZE_WINDOW = 7.days

  enum :kind, { task: 0, event: 1, trigger: 2 }

  # 50-year horizon for resolving occurrence_count → until_on. Plenty for any
  # realistic schedule and bounded so a bad rule can't loop forever.
  OCCURRENCE_SCAN_CAP = 50.years

  before_save :sync_until_on_from_occurrence_count, if: -> { occurrence_count.present? }
  after_save :materialize_upcoming_triggers!, if: :saved_change_to_anything_affecting_triggers?

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

  # Serialized snapshot of the recurrence config for prefilling the edit modal.
  # Emitted as `data-schedule` on rendered items so the JS can hydrate without
  # an extra round-trip.
  def serialize_for_edit
    {
      id:                 id,
      freq:               freq,
      by_day:             Array(recurrence_data[:by_day]),
      by_month_day:       Array(recurrence_data[:by_month_day]).map(&:to_i),
      interval:           recurrence_data[:interval]&.to_i,
      unit:               recurrence_data[:unit],
      by_set_pos:         recurrence_data[:by_set_pos]&.to_i,
      starts_on:          starts_on&.iso8601,
      until_on:           until_on&.iso8601,
      occurrence_count:   occurrence_count,
      color:              color,
      trigger_expression: trigger_expression,
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
  def build_phantom(date)
    AgendaItem.new(
      agenda:             agenda,
      agenda_schedule:    self,
      kind:               kind,
      start_at:           occurrence_start_at(date),
      end_at:             occurrence_end_at(date),
      name:               name,
      notes:              notes,
      location:           location,
      color:              color,
      trigger_expression: trigger_expression,
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

  def occurrence_start_at(date)
    zone = user_zone
    zone.local(date.year, date.month, date.day, start_time.hour, start_time.min)
  end

  def occurrence_end_at(date)
    return nil unless event?
    return nil if duration_minutes.blank?

    occurrence_start_at(date) + duration_minutes.minutes
  end

  # Triggers need real AgendaItem rows for the firing worker to find them at
  # their scheduled time — phantoms aren't reliable for time-sensitive ops.
  # Persists a rolling TRIGGER_MATERIALIZE_WINDOW of upcoming occurrences.
  def materialize_upcoming_triggers!(through: TRIGGER_MATERIALIZE_WINDOW.from_now)
    return unless trigger?

    from = Date.current
    to = through.to_date

    existing_dates = agenda_items
      .where(start_at: agenda.send(:day_range, from).begin..agenda.send(:day_range, to).end)
      .filter_map { |item| item.start_at.in_time_zone(user.timezone).to_date }
      .to_set

    (from..to).each do |date|
      next unless matches?(date)
      next if existing_dates.include?(date)

      agenda_items.create!(
        agenda:             agenda,
        kind:               :trigger,
        name:               name,
        start_at:           occurrence_start_at(date),
        color:              color,
        notes:              notes,
        location:           location,
        trigger_expression: trigger_expression,
      )
    end
  end

  private

  def saved_change_to_anything_affecting_triggers?
    trigger? && (
      saved_change_to_starts_on? || saved_change_to_until_on? ||
      saved_change_to_recurrence? || saved_change_to_start_time? ||
      saved_change_to_kind? || saved_change_to_name? ||
      saved_change_to_trigger_expression? ||
      previously_new_record?
    )
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
