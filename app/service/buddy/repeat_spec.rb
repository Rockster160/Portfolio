module Buddy
  # Turns the colon-separated `repeat` string the model writes into the rule
  # hash Recurrence reads.
  #
  # A compact string rather than six separate tool arguments on purpose: the
  # model writes one thing, and a spec that's wrong is wrong visibly rather
  # than as a quiet disagreement between `freq` and `by_set_pos`. Anything this
  # can't read returns nil and the tool says so, which is better than the
  # previous shape's habit of building a half-hash out of the parts it
  # recognised.
  #
  #   daily:09:00                 every day
  #   weekdays:07:54              Mon-Fri
  #   weekly:mon,wed,fri:07:30    those days each week
  #   monthly:1:09:00             the 1st of the month
  #   monthly:2-tuesday:10:00     the SECOND TUESDAY of the month
  #   monthly:last-friday:17:00   the last Friday
  #   every:2-weeks:10:00         every other week, on `on`'s weekday
  #   yearly:09:00                once a year, on `on`'s date
  module RepeatSpec
    module_function

    WEEKDAYS = {
      "sun"       => "sun",
      "sunday"    => "sun",
      "mon"       => "mon",
      "monday"    => "mon",
      "tue"       => "tue",
      "tues"      => "tue",
      "tuesday"   => "tue",
      "wed"       => "wed",
      "weds"      => "wed",
      "wednesday" => "wed",
      "thu"       => "thu",
      "thur"      => "thu",
      "thurs"     => "thu",
      "thursday"  => "thu",
      "fri"       => "fri",
      "friday"    => "fri",
      "sat"       => "sat",
      "saturday"  => "sat",
    }.freeze

    ORDINALS = {
      "1"      => 1,
      "2"      => 2,
      "3"      => 3,
      "4"      => 4,
      "last"   => -1,
      "first"  => 1,
      "second" => 2,
      "third"  => 3,
      "fourth" => 4,
    }.freeze

    UNITS = {
      "day"     => "day",
      "days"    => "day",
      "daily"   => "day",
      "week"    => "week",
      "weeks"   => "week",
      "weekly"  => "week",
      "month"   => "month",
      "months"  => "month",
      "monthly" => "month",
    }.freeze

    def parse(spec, on: Date.current)
      parts = spec.to_s.strip.downcase.split(":")
      return nil if parts.empty?

      kind = parts.shift
      # Everything trailing is the clock, so "weekly:mon:07:30" splits cleanly
      # whether or not the middle part is there.
      case kind
      when "daily"    then base("daily", parts, on)
      when "weekdays" then base("weekdays", parts, on)
      when "yearly"   then base("yearly", parts, on)
      when "weekly"   then weekly(parts, on)
      when "monthly"  then monthly(parts, on)
      when "every"    then every(parts, on)
      end
    end

    def base(freq, parts, on)
      at = clock(parts)
      return nil if at.nil?

      { "freq" => freq, "at" => at, "starts_on" => on.iso8601 }
    end

    def weekly(parts, on)
      days = days_in(parts.shift)
      at   = clock(parts)
      return nil if days.empty? || at.nil?

      { "freq" => "weekly", "by_day" => days, "at" => at, "starts_on" => on.iso8601 }
    end

    # Two rules under one word: a date of the month, or the Nth weekday of it.
    # "2-tuesday" is the second Tuesday; a bare "2" is the 2nd.
    def monthly(parts, on)
      anchor = parts.shift.to_s
      at     = clock(parts)
      return nil if at.nil?

      rule = { "freq" => "monthly", "at" => at, "starts_on" => on.iso8601 }
      if anchor.include?("-")
        nth, day = anchor.split("-", 2)
        pos = ORDINALS[nth.to_s]
        key = WEEKDAYS[day.to_s]
        return nil if pos.nil? || key.nil?

        return rule.merge("by_set_pos" => pos, "by_day" => [key])
      end

      dom = anchor.to_i
      return nil unless dom == -1 || dom.between?(1, 31)

      rule.merge("by_month_day" => [dom])
    end

    # "every:2-weeks:10:00". The interval counts from `on`, so every-2-weeks
    # set on a Tuesday lands on Tuesdays.
    def every(parts, on)
      spec = parts.shift.to_s
      at   = clock(parts)
      return nil if at.nil? || spec.exclude?("-")

      count, unit = spec.split("-", 2)
      n = count.to_i
      u = UNITS[unit.to_s]
      return nil if u.nil? || !n.between?(1, 52)

      { "freq" => "custom", "interval" => n, "unit" => u, "at" => at, "starts_on" => on.iso8601 }
    end

    def days_in(text)
      text.to_s.split(/[,\s]+/).filter_map { |d| WEEKDAYS[d.strip] }.uniq
    end

    # Whatever's left is HH:MM. Rejected rather than defaulted - a reminder at
    # a time nobody asked for is worse than being told the spec was unreadable.
    def clock(parts)
      hh, mm = parts
      return nil unless hh.to_s.match?(/\A\d{1,2}\z/) && mm.to_s.match?(/\A\d{2}\z/)
      return nil unless hh.to_i.between?(0, 23) && mm.to_i.between?(0, 59)

      format("%<hour>02d:%<minute>02d", hour: hh.to_i, minute: mm.to_i)
    end
  end
end
