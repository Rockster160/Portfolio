module Buddy
  # "Buddy is sleeping" state, driven by Anthropic API usage-cap errors
  # that come back through the Mac. When Mac's claude -p reports "out
  # of extra usage / resets HH:MMam", Rails records the reset time on
  # users.buddy_sleep_until and Buddy stops trying to dispatch turns
  # until that time passes. Incoming messages while asleep get an
  # immediate in-character "sleeping until X" reply instead of a
  # dispatch-and-fail.
  module SleepGuard
    module_function

    # Regex that matches the shape of Anthropic's usage-cap error text.
    # Tries to be forgiving about capitalization and connector chars.
    # Extracts a time like "11:20am" and optional "(America/Denver)".
    ERROR_RX = /out of (?:extra )?usage.*?resets\s+(?<time>\d{1,2}(?::\d{2})?\s*(?:am|pm)?)(?:\s*\(?(?<tz>[A-Za-z_\/\-]+)\)?)?/i

    # Parse the message body from Mac and, if it's a usage-cap error,
    # extract the ISO reset timestamp. Returns nil on no match.
    def parse_reset_time(body, default_tz: "America/Denver")
      m = ERROR_RX.match(body.to_s)
      return nil unless m

      tz_name = m[:tz].presence || default_tz
      time_str = m[:time].to_s.strip
      begin
        zone = ActiveSupport::TimeZone[tz_name] || Time.zone
        parsed = zone.parse(time_str)
        return nil unless parsed

        # If the parsed time is in the past for today, roll to tomorrow.
        parsed += 1.day if parsed < zone.now
        parsed
      rescue
        nil
      end
    end

    # Mark the user asleep until `until_time`, broadcast the expression
    # change, and drop the pending reminder if the wake time is soon.
    def sleep_until!(user, until_time)
      return if until_time.nil? || until_time < Time.current

      user.update!(buddy_sleep_until: until_time)
      Buddy::ExpressionState.set(user, :sleeping)
    end

    def sleeping?(user)
      user.buddy_sleep_until.present? && user.buddy_sleep_until > Time.current
    end

    # Called on message dispatch. If the user was asleep and the sleep
    # window passed, clear the column and shift back to neutral.
    def maybe_wake!(user)
      return unless user.buddy_sleep_until.present?
      return if user.buddy_sleep_until > Time.current

      user.update!(buddy_sleep_until: nil)
      Buddy::ExpressionState.set(user, :neutral)
    end

    # Friendly wake-time string for the sleeping reply.
    def wake_string(user)
      return "later" if user.buddy_sleep_until.nil?

      user.buddy_sleep_until
        .in_time_zone(user.timezone)
        .strftime("%-I:%M %p")
    end

    # Buddy's in-character reply while asleep. Personalized to the theme.
    def sleeping_reply_body(user)
      name = user.buddy_theme.to_s == "moss" ? "Moss" : "Byte"
      "💤 #{name} is sleeping right now. They'll be back up at #{wake_string(user)}."
    end
  end
end
