module Buddy
  # Turns the free-form `schedule` phrase a person hands Buddy ("every Sunday",
  # "weekdays", "every 3 days", "monthly on the 1st") into the `recurrence`
  # JSONB hash the Chore model reads. The chore FORM builds this hash from UI
  # controls, and there's no server-side NL parser anywhere else, so Buddy needs
  # its own. Output keys/values match exactly what Chore#recurrence_data +
  # #matches_day? consume: string `freq`, `by_day` as 3-letter WEEKDAY_KEYS,
  # `by_month_day` ints, `interval` + `unit` (day/week/month) for custom.
  #
  # Returns nil when the phrase is blank or explicitly one-off, and also when it
  # can't confidently parse — the caller then treats the chore as one-off rather
  # than inventing a schedule (missing beats wrong, per house rules).
  module ChoreScheduleParser
    module_function

    ORDER    = %w[sun mon tue wed thu fri sat].freeze
    WEEKDAYS = {
      "sunday"    => "sun",
      "monday"    => "mon",
      "tuesday"   => "tue",
      "wednesday" => "wed",
      "thursday"  => "thu",
      "friday"    => "fri",
      "saturday"  => "sat",
      "sun"       => "sun",
      "mon"       => "mon",
      "tue"       => "tue",
      "tues"      => "tue",
      "wed"       => "wed",
      "weds"      => "wed",
      "thu"       => "thu",
      "thur"      => "thu",
      "thurs"     => "thu",
      "fri"       => "fri",
      "sat"       => "sat",
    }.freeze

    # `on` is the anchor date (the user's perceived today) — used to fill a
    # sensible weekday for a bare "weekly" so it doesn't become a never-firing
    # empty-by_day weekly.
    def parse(text, on: nil)
      raw = text.to_s.downcase.strip
      return nil if raw.empty? || raw.match?(/\A(once|one-?off|one off|just once|no repeat)\z/)

      return { "freq" => "daily" }    if raw.match?(/\b(daily|every ?day|each day|everyday)\b/)
      return { "freq" => "weekdays" } if raw.match?(/\b(weekdays?|every weekday|work ?days?)\b/)

      if (m = raw.match(/every\s+(\d+)\s+(day|week|month)s?/))
        return { "freq" => "custom", "interval" => m[1].to_i, "unit" => m[2] }
      end

      days = extract_weekdays(raw)
      return { "freq" => "weekly", "by_day" => days } if days.any?

      if raw.match?(/\bmonth(ly)?\b/)
        if (m = raw.match(/(\d{1,2})(?:st|nd|rd|th)?/))
          return { "freq" => "monthly", "by_month_day" => [m[1].to_i] }
        end

        return { "freq" => "monthly" }
      end

      return { "freq" => "yearly" }                       if raw.match?(/\b(year(ly)?|annual(ly)?)\b/)
      return weekly_on(on)                                if raw.match?(/\bweek(ly)?\b/)

      nil
    end

    def extract_weekdays(raw)
      found = WEEKDAYS.filter_map { |word, key| key if raw.match?(/\b#{Regexp.escape(word)}s?\b/) }
      ORDER.select { |k| found.include?(k) }
    end

    # A bare "weekly" with no named day fires every week on the anchor's
    # weekday (or Monday when we have no anchor), never an empty by_day.
    def weekly_on(on)
      key = ORDER[(on || Date.current).wday] rescue "mon"
      { "freq" => "weekly", "by_day" => [key] }
    end
  end
end
