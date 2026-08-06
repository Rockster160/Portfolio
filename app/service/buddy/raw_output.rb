module Buddy
  # Makes a Jil function's raw return value safe to hand to the model.
  #
  # Right now that means one thing: timestamps. A sensor reading comes back as
  # `kennel is closed (raw state: off, last changed:
  # 2026-08-05T18:58:03.888986+00:00)`, and the seed used to hand that over with
  # an instruction to convert the UTC stamp into local time. It doesn't. Prod
  # 2636 read 18:58Z back as "6:58 PM", which is the same number with the offset
  # thrown away — six hours wrong, and stated with total confidence.
  #
  # It's the lesson `iso_time` args already learned the hard way (see
  # Buddy::Tools::TYPE_HINTS, "never convert to UTC"): the model is fine at
  # reading a clock and bad at moving one. So the arithmetic happens here and
  # what reaches the model is already the time its person would say.
  module RawOutput
    module_function

    # ISO-8601 carrying an explicit zone, which is what Home Assistant and the
    # rest of the house emit. A stamp with NO zone is left alone: we'd only be
    # guessing which one it was in, and a wrong guess is the bug being fixed.
    STAMP_RX = /
      \d{4}-\d{2}-\d{2}
      [T ]
      \d{2}:\d{2}:\d{2}
      (?:\.\d+)?
      (?: Z | [+-]\d{2}:?\d{2} )
    /x

    def localize(text, user)
      today = Time.current.in_time_zone(zone_for(user)).to_date
      text.to_s.gsub(STAMP_RX) { |stamp| phrase(stamp, user, today) || stamp }
    end

    def phrase(stamp, user, today)
      time = Time.zone.parse(stamp)
      return nil if time.nil?

      local = time.in_time_zone(zone_for(user))
      clock = local.strftime("%-I:%M %p")
      case (local.to_date - today).to_i
      when 0  then "#{clock} today"
      when -1 then "#{clock} yesterday"
      when 1  then "#{clock} tomorrow"
      else         "#{clock} on #{local.strftime("%b %-d")}"
      end
    rescue ArgumentError
      nil
    end

    def zone_for(user)
      ActiveSupport::TimeZone[user.timezone.to_s] || Time.zone
    end
  end
end
