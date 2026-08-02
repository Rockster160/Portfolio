module Buddy
  # Parses the natural-language time expressions Buddy passes for
  # backdating (chore completions, event logs, etc.). Handles:
  #   - ISO timestamps ("2026-07-27T14:00-06:00")
  #   - Relative phrases ("an hour ago", "30 minutes ago", "2 hours ago")
  #   - Time-of-day words ("this morning", "this afternoon", "tonight")
  #   - Bare clock times ("8:15am", "3 PM", "7pm") - resolved to today in
  #     the user's TZ, or yesterday if that's already in the future
  #
  # Always returns a Time in the user's zone, or nil if unparseable.
  # `friendly` renders "3:14 PM" style for confirmation UIs.
  module TimeParser
    module_function

    RELATIVE_RE = /\A(an?|\d+)\s*(minute|min|hour|hr|day)s?\s+ago\z/i.freeze
    CLOCK_RE    = /\A(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\z/i.freeze

    def parse_past(input, user: nil)
      return nil if input.blank?

      str = input.to_s.strip.downcase
      return nil if str.in?(%w[now just_now just-now])

      zone = user_zone(user)
      Time.use_zone(zone) {
        parse_iso(str) ||
          parse_relative(str) ||
          parse_time_of_day(str) ||
          parse_clock(str)
      }
    end

    def friendly(value, user: nil)
      time = value.is_a?(Time) ? value : (Time.zone.parse(value.to_s) rescue nil)
      return value.to_s if time.nil?

      time = time.in_time_zone(user_zone(user))
      today = Time.current.in_time_zone(user_zone(user)).to_date
      day_label = case time.to_date
      when today          then nil
      when today - 1      then "yesterday "
      else                     "#{time.strftime('%a')} "
      end
      "#{day_label}#{time.strftime('%-I:%M %p').sub(':00', '').downcase.sub(/(am|pm)/) { $1 }}"
    end

    class << self
      private

      def user_zone(user)
        Buddy::Day.zone(user).name
      end

      def parse_iso(str)
        return nil unless str.match?(/\A\d{4}-\d{2}-\d{2}/)

        Time.zone.parse(str)
      rescue ArgumentError
        nil
      end

      def parse_relative(str)
        m = str.match(RELATIVE_RE)
        return nil unless m

        n = m[1].match?(/\d/) ? m[1].to_i : 1
        unit = m[2]
        secs = case unit
        when "minute", "min" then n * 60
        when "hour", "hr"    then n * 3600
        when "day"           then n * 86_400
        end
        Time.current - secs.seconds
      end

      def parse_time_of_day(str)
        today = Time.current.in_time_zone.to_date
        case str
        when "this morning", "morning"       then Time.zone.local(today.year, today.month, today.day, 8)
        when "this afternoon", "afternoon"   then Time.zone.local(today.year, today.month, today.day, 14)
        when "this evening", "evening"       then Time.zone.local(today.year, today.month, today.day, 19)
        when "tonight"                       then Time.zone.local(today.year, today.month, today.day, 21)
        when "earlier", "earlier today"      then Time.current - 2.hours
        when "yesterday"                     then Time.zone.local(today.year, today.month, today.day, 14) - 1.day
        end
      end

      def parse_clock(str)
        m = str.match(CLOCK_RE)
        return nil unless m

        hour   = m[1].to_i
        minute = m[2].to_i
        meridiem = m[3]
        hour += 12 if meridiem == "pm" && hour < 12
        hour = 0   if meridiem == "am" && hour == 12
        return nil unless hour.between?(0, 23) && minute.between?(0, 59)

        today = Time.current.in_time_zone.to_date
        candidate = Time.zone.local(today.year, today.month, today.day, hour, minute)
        # If they said "8am" and it's now 6am, they likely mean yesterday's 8am.
        candidate -= 1.day if candidate > Time.current
        candidate
      end
    end
  end
end
