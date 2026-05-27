# Translates RFC-5545 RRULE strings (as Google emits them) onto the JSONB
# `recurrence` shape AgendaSchedule already understands. Google's recurrence
# field is an array of strings — RRULE/EXDATE/RDATE lines.
#
# Return shape: { recurrence:, until_on:, occurrence_count:, partial:, skip: }
#   * recurrence       — Hash to merge into AgendaSchedule#recurrence
#   * until_on         — Date or nil (separate AR column)
#   * occurrence_count — Integer or nil (separate AR column)
#   * partial          — true when the source rule has fidelity we can't
#                        fully represent (multiple RRULEs, multi-month
#                        BYMONTH, BYYEARDAY/BYWEEKNO refinements). Caller
#                        may surface this to the user as a "best-effort"
#                        notice.
#   * skip             — true when the rule has granularity we don't model
#                        at all (HOURLY/MINUTELY/SECONDLY). Caller should
#                        NOT create a schedule.
#
# Returns nil if the input has no RRULE lines.
class GoogleCalendar::RRule
  WEEKDAY_MAP = {
    "SU" => :sun,
    "MO" => :mon,
    "TU" => :tue,
    "WE" => :wed,
    "TH" => :thu,
    "FR" => :fri,
    "SA" => :sat,
  }.freeze
  WEEKDAYS_MF = %w[MO TU WE TH FR].freeze
  SUB_DAY_FREQS = %w[HOURLY MINUTELY SECONDLY].freeze
  UNREPRESENTABLE_PARTS = %w[BYYEARDAY BYWEEKNO BYHOUR BYMINUTE BYSECOND].freeze

  def self.translate(lines)
    rrule_lines = []
    exdates = []
    rdates = []

    Array(lines).each do |line|
      kind, value = line.to_s.split(":", 2)
      next if kind.blank? || value.blank?

      base = kind.split(";").first.to_s.upcase
      case base
      when "RRULE"  then rrule_lines << value
      when "EXDATE" then exdates.concat(value.split(",").filter_map { |d| parse_date(d) })
      when "RDATE"  then rdates.concat(value.split(",").filter_map { |d| parse_date(d) })
      end
    end

    return nil if rrule_lines.empty?

    primary = parse_rrule(rrule_lines.first)
    return primary.merge(skip: true) if primary[:skip]

    recurrence = primary[:recurrence].dup
    recurrence[:excluded_dates] = exdates.map(&:to_s) if exdates.any?
    recurrence[:included_dates] = rdates.map(&:to_s) if rdates.any?

    partial = primary[:partial]
    # Multiple RRULEs on one event — RFC allows it, we only honor the first.
    partial ||= rrule_lines.size > 1

    {
      recurrence:       recurrence,
      until_on:         primary[:until_on],
      occurrence_count: primary[:occurrence_count],
      partial:          partial,
      skip:             false,
    }
  end

  def self.parse_rrule(value)
    parts = value.split(";").to_h { |pair|
      k, v = pair.split("=", 2)
      [k.to_s.upcase, v.to_s]
    }

    freq = parts["FREQ"].to_s.upcase
    return { skip: true, partial: false, recurrence: {}, until_on: nil, occurrence_count: nil } if SUB_DAY_FREQS.include?(freq)

    interval = parts["INTERVAL"].to_i
    interval = 1 if interval < 1
    by_day = parts["BYDAY"].to_s.split(",").map(&:upcase)
    by_md = parts["BYMONTHDAY"].to_s.split(",").map(&:to_i).reject(&:zero?)
    by_month = parts["BYMONTH"].to_s.split(",").map(&:to_i).reject(&:zero?)
    by_setpos = parts["BYSETPOS"].to_i

    recurrence = build_recurrence(freq, interval, by_day, by_md, by_setpos)

    partial = (by_month.size > 1) || UNREPRESENTABLE_PARTS.any? { |k| parts.key?(k) }

    {
      recurrence:       recurrence,
      until_on:         parts["UNTIL"].present? ? parse_date(parts["UNTIL"]) : nil,
      occurrence_count: parts["COUNT"].present? ? parts["COUNT"].to_i : nil,
      partial:          partial,
      skip:             false,
    }
  end

  def self.build_recurrence(freq, interval, by_day, by_md, by_setpos)
    case freq
    when "DAILY"
      interval == 1 ? { freq: :daily } : { freq: :custom, unit: :day, interval: interval }
    when "WEEKLY"
      days = by_day.filter_map { |code| WEEKDAY_MAP[code[-2..]] }.map(&:to_s)
      if interval == 1 && by_day.pluck(-2..).sort == WEEKDAYS_MF.sort && days.size == 5
        { freq: :weekdays }
      elsif interval == 1
        { freq: :weekly, by_day: days.presence || [] }
      else
        { freq: :custom, unit: :week, interval: interval, by_day: days }
      end
    when "MONTHLY"
      if by_setpos.nonzero? && by_day.any?
        { freq: :monthly, by_set_pos: by_setpos, by_day: [WEEKDAY_MAP[by_day.first[-2..]].to_s] }
      elsif by_md.any?
        { freq: :monthly, by_month_day: by_md }
      else
        { freq: :monthly }
      end
    when "YEARLY"
      { freq: :yearly }
    else
      { freq: :custom, unit: :day, interval: interval }
    end
  end

  # Build an array of RRULE/EXDATE lines for an AgendaSchedule — the inverse
  # of `translate`. Used when our UI's "delete all future" needs to push a
  # truncated rule back to Google's master event.
  # Returns [] when the schedule has no representable rule (one-off, etc.).
  def self.serialize(schedule, until_on: nil)
    rec = (schedule.recurrence || {}).with_indifferent_access
    freq = rec[:freq].to_s
    return [] if freq.blank?

    lines = []
    rrule_parts = []

    case freq
    when "daily"
      rrule_parts << "FREQ=DAILY"
    when "weekdays"
      rrule_parts << "FREQ=WEEKLY"
      rrule_parts << "BYDAY=MO,TU,WE,TH,FR"
    when "weekly"
      rrule_parts << "FREQ=WEEKLY"
      days = Array(rec[:by_day]).map { |d| WEEKDAY_MAP.invert[d.to_sym] }.compact
      rrule_parts << "BYDAY=#{days.join(",")}" if days.any?
    when "monthly"
      rrule_parts << "FREQ=MONTHLY"
      if rec[:by_set_pos].present? && Array(rec[:by_day]).any?
        rrule_parts << "BYSETPOS=#{rec[:by_set_pos]}"
        day = WEEKDAY_MAP.invert[rec[:by_day].first.to_sym]
        rrule_parts << "BYDAY=#{day}" if day
      elsif Array(rec[:by_month_day]).any?
        rrule_parts << "BYMONTHDAY=#{rec[:by_month_day].join(",")}"
      end
    when "yearly"
      rrule_parts << "FREQ=YEARLY"
    when "custom"
      unit = (rec[:unit].to_s.presence || "day").upcase
      unit = "DAY" if unit == "DAYS"
      rrule_parts << "FREQ=#{unit_to_freq(unit)}"
      interval = rec[:interval].to_i
      rrule_parts << "INTERVAL=#{interval}" if interval > 1
    else
      return []
    end

    truncate_to = until_on || schedule.until_on
    rrule_parts << "UNTIL=#{truncate_to.strftime("%Y%m%d")}" if truncate_to
    rrule_parts << "COUNT=#{schedule.occurrence_count}" if schedule.occurrence_count.present? && truncate_to.nil?

    lines << "RRULE:#{rrule_parts.join(";")}"

    excluded = Array(rec[:excluded_dates]).filter_map { |d| parse_date_str(d) }
    if excluded.any?
      lines << "EXDATE:#{excluded.map { |d| d.strftime("%Y%m%d") }.join(",")}"
    end

    lines
  end

  def self.unit_to_freq(unit)
    case unit
    when "WEEK"  then "WEEKLY"
    when "MONTH" then "MONTHLY"
    else "DAILY"
    end
  end

  def self.parse_date_str(value)
    return value if value.is_a?(::Date)

    ::Date.parse(value.to_s)
  rescue ::ArgumentError
    nil
  end

  # Google date forms: `YYYYMMDD`, `YYYYMMDDTHHMMSSZ`, or `YYYYMMDDTHHMMSS`.
  # We only need the calendar date — time-of-day comes from the event's
  # start.dateTime which is captured separately.
  def self.parse_date(str)
    return nil if str.blank?

    digits = str.to_s.split("T", 2).first
    return nil unless digits.match?(/\A\d{8}\z/)

    ::Date.new(digits[0, 4].to_i, digits[4, 2].to_i, digits[6, 2].to_i)
  rescue ::ArgumentError
    nil
  end
end
