module Buddy
  # When a request says to do something LATER, and when that is: "turn the TV
  # off in 30", "in half an hour", "at 11", "ten minutes from now".
  #
  # Buddy::GPT::Turn reads this off the person's own words so a call that acts
  # the moment it runs can be put on the clock for them, rather than run now or
  # refused. Only a time that can be pinned to a moment counts - "tonight",
  # "before bed" and "when I get home" are later too, but they say nothing about
  # WHEN, and guessing one would do the thing at an hour nobody chose.
  module DeferredTime
    module_function

    WORD_NUMBERS = {
      "a"           => 1,
      "an"          => 1,
      "one"         => 1,
      "two"         => 2,
      "three"       => 3,
      "four"        => 4,
      "five"        => 5,
      "six"         => 6,
      "seven"       => 7,
      "eight"       => 8,
      "nine"        => 9,
      "ten"         => 10,
      "eleven"      => 11,
      "twelve"      => 12,
      "fifteen"     => 15,
      "twenty"      => 20,
      "thirty"      => 30,
      "forty"       => 40,
      "forty-five"  => 45,
      "fifty"       => 50,
      "sixty"       => 60,
      "ninety"      => 90,
      "couple"      => 2,
      "a couple"    => 2,
      "a couple of" => 2,
    }.freeze

    NUMBER = /(\d+(?:\.\d+)?|#{WORD_NUMBERS.keys.sort_by { |k| -k.length }.map { |k| Regexp.escape(k) }.join("|")})/
    UNIT   = /(sec(?:ond)?s?|min(?:ute)?s?|h(?:ou)?rs?|hours?)/

    # Further out than this is a schedule, not a wait (Buddy::Timers caps at a
    # day), and a misread that far off is worse than asking.
    MAX_AHEAD = 24.hours

    # "in 30 minutes", "in an hour and a half", "in 2.5 hours"
    IN_UNIT_RX    = /\bin\s+(?:about\s+|like\s+|around\s+)?#{NUMBER}\s*(?:and\s+a\s+half\s+)?#{UNIT}(?:\s+and\s+a\s+half)?\b/i
    # "in half an hour"
    HALF_HOUR_RX  = /\bin\s+(?:about\s+)?half\s+an?\s+hour\b/i
    # "ten minutes from now", "after 10 minutes"
    FROM_NOW_RX   = /\b#{NUMBER}\s*#{UNIT}\s+from\s+now\b/i
    AFTER_UNIT_RX = /\bafter\s+#{NUMBER}\s*#{UNIT}\b/i
    # "TV off in 30" - a bare number after "in" is minutes. Never a percent or
    # a temperature, and never a year.
    BARE_IN_RX    = /\bin\s+(\d{1,3})\b(?!\s*(?:%|percent|degrees?|°|[a-z]))/i
    # "at 11", "at 10:30pm", "at 22:15". A bare 13 to 23 is a level ("set the
    # fan at 20"), so the 24-hour clock only counts with its minutes.
    CLOCK_RX      = /\bat\s+(?:(1[0-2]|0?[1-9])(?::([0-5]\d))?\s*(am|pm|a\.m\.|p\.m\.)?|(1[3-9]|2[0-3]):([0-5]\d))(?!\s*(?:%|percent|degrees?|°|\d))/i
    NOON_RX       = /\bat\s+(noon|midnight)\b/i

    # The moment the request means, or nil when it names none.
    def at(text, user:, now: Time.current)
      text = text.to_s
      return nil if text.strip.empty?

      zone = user&.timezone.presence || Time.zone.name
      local_now = now.in_time_zone(zone)

      found = delay(text)&.then { |seconds| local_now + seconds } || clock(text, local_now)
      return nil if found.nil? || found <= now || found > now + MAX_AHEAD

      found
    end

    def delay(text)
      return 30.minutes if text.match?(HALF_HOUR_RX)

      [IN_UNIT_RX, FROM_NOW_RX, AFTER_UNIT_RX].each { |rx|
        m = text.match(rx)
        next if m.nil?

        amount = number(m[1])
        next if amount.nil?

        amount += 0.5 if m[0].match?(/and\s+a\s+half/i)
        return (amount * unit_seconds(m[2])).round
      }

      m = text.match(BARE_IN_RX)
      m && m[1].to_i.positive? ? m[1].to_i.minutes : nil
    end

    def clock(text, local_now)
      if (m = text.match(NOON_RX))
        hour = m[1].casecmp?("noon") ? 12 : 0
        return next_at(local_now, hour, 0)
      end

      m = text.match(CLOCK_RX)
      return nil if m.nil?
      return next_at(local_now, m[4].to_i, m[5].to_i) if m[4]

      hour   = m[1].to_i
      minute = m[2].to_i
      half   = m[3].to_s.delete(".").downcase
      if half.present?
        hour = (hour % 12) + (half == "pm" ? 12 : 0)
        return next_at(local_now, hour, minute)
      end

      # "At 11" with no am or pm is whichever 11 comes next.
      [next_at(local_now, hour % 12, minute), next_at(local_now, (hour % 12) + 12, minute)].min
    end

    def next_at(local_now, hour, minute)
      time = local_now.change(hour: hour, min: minute, sec: 0)
      time <= local_now ? time + 1.day : time
    end

    def number(word)
      key = word.to_s.downcase.strip
      return key.to_f if key.match?(/\A\d+(?:\.\d+)?\z/)

      WORD_NUMBERS[key]&.to_f
    end

    def unit_seconds(unit)
      case unit.to_s.downcase
      when /\As/ then 1
      when /\Am/ then 60
      else 3600
      end
    end
  end
end
