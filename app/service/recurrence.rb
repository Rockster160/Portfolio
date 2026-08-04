# "Every weekday", "the second Tuesday of the month", "every other Thursday".
#
# A pure value object over a recurrence rule and the window it runs in. No
# database, no timezone state, no knowledge of what's recurring - it answers
# whether a DATE is in the pattern, and walks forward to the next one that is.
#
# Lifted out of AgendaSchedule, which owned this and still holds every other
# concern a calendar series has (materializing rows, phantoms, Google sync).
# BuddyReminder needed the same rules and had a fraction of them - four
# frequencies with no interval, no nth-weekday, no end date - so "remind me
# every second Tuesday" was a thing the calendar could express and a reminder
# could not, for no reason other than which file the code happened to live in.
#
# The rule is the shape AgendaSchedule already stored, so nothing about the
# calendar's data had to change:
#
#   { freq: :weekly,  by_day: [:mon, :wed] }
#   { freq: :monthly, by_month_day: [1, 15] }
#   { freq: :monthly, by_set_pos: 2, by_day: [:tue] }   # second Tuesday
#   { freq: :monthly, by_set_pos: -1, by_day: [:fri] }  # last Friday
#   { freq: :custom,  interval: 2, unit: :week }        # every other <starts_on's weekday>
#
# There is a JS port of this at app/javascript/src/agenda_store/recurrence.js
# and spec/javascript/recurrence_parity_spec.rb runs both over the same rules
# and diffs the results. A new branch here MUST be ported there in the same
# change, or the calendar renders different days depending on whether the page
# hit the server.
class Recurrence
  FREQUENCIES  = %i[daily weekdays weekly monthly yearly custom].freeze
  WEEKDAY_KEYS = %i[sun mon tue wed thu fri sat].freeze
  CUSTOM_UNITS = %i[day week month].freeze

  # How far `next_on_or_after` will walk before giving up. A yearly rule needs
  # 366 in the worst case and a custom monthly interval of 12 needs about the
  # same; five years is slack on both and bounds a rule that matches nothing at
  # all (a `weekly` with an empty `by_day` that somehow got past validation)
  # rather than hanging the request that asked.
  SCAN_LIMIT_DAYS = 5 * 366

  # Resolving "stop after N times" into a concrete end date. 50 years is far
  # past any real schedule and keeps a bad rule from looping forever.
  OCCURRENCE_SCAN_CAP = 50.years

  attr_reader :starts_on, :until_on

  def initialize(rule, starts_on:, until_on: nil)
    @rule      = (rule || {}).with_indifferent_access
    @starts_on = starts_on&.to_date
    @until_on  = until_on&.to_date
  end

  def freq
    (@rule[:freq].to_s.presence || :daily).to_sym
  end

  def valid_freq?
    FREQUENCIES.include?(freq)
  end

  def interval = [@rule[:interval].to_i, 1].max
  def set_pos  = @rule[:by_set_pos].presence&.to_i

  def unit
    given = (@rule[:unit].to_s.presence || :day).to_sym
    CUSTOM_UNITS.include?(given) ? given : :day
  end

  def by_day
    Array(@rule[:by_day]).map { |d| d.to_s.downcase }
  end

  def excluded_dates
    Array(@rule[:excluded_dates]).filter_map { |d| Date.parse(d.to_s) rescue nil }.to_set
  end

  # Is `date` an occurrence? Answers the whole question, end date included.
  def matches?(date)
    date = date.to_date
    return false if until_on.present? && date > until_on

    matches_rule?(date)
  end

  # The pattern alone, ignoring the end date. Split out because resolving
  # "stop after N" walks the rule to DERIVE the end date, and consulting a
  # bound that doesn't exist yet would cut the walk short.
  def matches_rule?(date)
    date = date.to_date
    return false if starts_on.nil? || date < starts_on
    return false if excluded_dates.include?(date)

    case freq
    when :daily    then true
    when :weekdays then (1..5).cover?(date.wday)
    when :weekly   then weekday_indices.include?(date.wday)
    when :monthly  then matches_month_day?(date)
    when :yearly   then date.month == starts_on.month && date.day == starts_on.day
    when :custom   then matches_custom?(date)
    else                false
    end
  end

  # First occurrence on or after `date`, or nil if the rule runs out first.
  def next_on_or_after(date)
    cursor = [date.to_date, starts_on].compact.max
    return nil if cursor.nil?

    SCAN_LIMIT_DAYS.times do
      return nil if until_on.present? && cursor > until_on
      return cursor if matches?(cursor)

      cursor += 1
    end
    nil
  end

  # Every occurrence in [from..to]. Bounded by the rule's own window so a
  # request for the next decade doesn't iterate years that can't match.
  def between(from, to)
    lower = [from.to_date, starts_on].compact.max
    upper = until_on.present? ? [to.to_date, until_on].min : to.to_date
    return [] if lower.nil? || upper < lower

    (lower..upper).select { |date| matches?(date) }
  end

  # The date the Nth occurrence lands on, for "stop after 10 times". Returns
  # nil when the rule runs dry first.
  def date_of_occurrence(count)
    remaining = count.to_i
    return nil if remaining <= 0 || starts_on.nil?

    date = starts_on
    cap  = starts_on + OCCURRENCE_SCAN_CAP
    last = nil
    while date <= cap && remaining.positive?
      if matches_rule?(date)
        last = date
        remaining -= 1
      end
      date += 1
    end
    last
  end

  private

  def weekday_indices
    by_day.filter_map { |d| WEEKDAY_KEYS.index(d.to_sym) }.presence || [starts_on.wday]
  end

  def month_days
    Array(@rule[:by_month_day]).map(&:to_i).presence || [starts_on.day]
  end

  def matches_month_day?(date)
    # Monthly + Nth weekday - "third Tuesday of every month". When the rule
    # carries both `by_set_pos` and `by_day`, `by_month_day` is ignored.
    return matches_nth_weekday_of_month?(date) if set_pos.present? && by_day.any?

    month_days.include?(date.day) || (month_days.include?(-1) && date.day == date.end_of_month.day)
  end

  def matches_custom?(date)
    case unit
    when :day   then ((date - starts_on).to_i % interval).zero?
    when :week  then (((date - starts_on).to_i / 7) % interval).zero? && date.wday == starts_on.wday
    when :month then matches_custom_month?(date)
    end
  end

  def matches_custom_month?(date)
    return false unless (months_between(starts_on, date) % interval).zero?
    return matches_nth_weekday_of_month?(date) if set_pos.present? && by_day.any?
    return matches_month_day?(date) if Array(@rule[:by_month_day]).any?

    date.day == starts_on.day
  end

  # "Second Thursday", "last Friday". `set_pos` is 1..4 or -1 for last.
  def matches_nth_weekday_of_month?(date)
    target = WEEKDAY_KEYS.index(by_day.first.to_s.to_sym)
    return false if target.nil? || date.wday != target
    return (date + 7).month != date.month if set_pos == -1

    (((date.day - 1) / 7) + 1) == set_pos
  end

  def months_between(from, to)
    ((to.year - from.year) * 12) + (to.month - from.month)
  end
end
