module ScheduleCondition
  # The `time` kind: whether a moment falls inside a window of the day, on
  # the days named. Stored as HH:MM strings and `wday` numbers, so a window
  # compares as plain values and reads back the same out of a jsonb column.
  module TimeWindow
    module_function

    # Day words a time condition takes, as `wday` numbers.
    DAY_SETS = {
      "weekdays" => [1, 2, 3, 4, 5],
      "weekends" => [0, 6],
      "everyday" => (0..6).to_a,
    }.freeze
    DAY_NAMES = %w[sun mon tue wed thu fri sat].freeze

    def normalize(data)
      out = {
        after:  (clock_of(data[:after]) if data[:after].present?),
        before: (clock_of(data[:before]) if data[:before].present?),
        days:   (days_of(data[:days]) if data[:days].present?),
      }.compact
      raise "a time condition needs `after`, `before` or `days`" if out.empty?

      out
    end

    # A window that ends before it starts runs over midnight: "after 10pm,
    # before 6am" is the night, not an empty set. `days` is the day the moment
    # falls on, so 1am Saturday is a weekend even inside Friday night's window.
    def inside?(data, now)
      return false if data[:days].present? && data[:days].exclude?(now.wday)

      clock  = now.strftime("%H:%M")
      after  = data[:after]
      before = data[:before]
      return true if after.nil? && before.nil?
      return clock >= after if before.nil?
      return clock < before if after.nil?

      after <= before ? (clock >= after && clock < before) : (clock >= after || clock < before)
    end

    def phrase(data)
      span = [
        ("after #{Buddy::Clock.at(data[:after])}" if data[:after]),
        ("before #{Buddy::Clock.at(data[:before])}" if data[:before]),
      ].compact.join(" and ")
      days  = data[:days]
      named = DAY_SETS.key(days) || days&.map { |d| DAY_NAMES[d].capitalize }&.to_sentence
      [span.presence, ("on #{named}" if named)].compact.join(" ")
    end

    # "22:00", "9:30", "10pm", "10:30 pm".
    def clock_of(value)
      match = value.to_s.strip.downcase.match(/\A(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\z/)
      raise "couldn't read #{value.inspect} as a time of day" if match.nil?

      hour = match[1].to_i
      min  = match[2].to_i
      hour = (hour % 12) + (match[3] == "pm" ? 12 : 0) if match[3]
      raise "couldn't read #{value.inspect} as a time of day" if hour > 23 || min > 59

      format("%<hour>02d:%<min>02d", hour: hour, min: min)
    end

    # Already a list of day numbers when it comes back out of the column.
    def days_of(value)
      return value.map(&:to_i).uniq.sort if value.is_a?(Array) && value.all? { |v| v.to_s.match?(/\A\d\z/) }

      words = Array.wrap(value).flat_map { |v| v.to_s.downcase.split(/[\s,]+/) }.compact_blank
      days = words.flat_map { |word|
        next DAY_SETS[word] if DAY_SETS.key?(word)

        idx = DAY_NAMES.index(word.first(3))
        raise "couldn't read #{word.inspect} as a day" if idx.nil?

        idx
      }
      days.uniq.sort
    end
  end
end
