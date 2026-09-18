module Buddy
  # A clock time the way a person reads one at a glance: "3pm", "3:15pm",
  # "3-4pm".
  #
  # "3:00 PM to 4:00 PM" is excessive and slow to read; "3-4pm" is the same
  # information at a glance.
  #
  # The rule was already in the codebase three times over and agreed with itself
  # nowhere. `TimeParser.friendly` wrote `%-I:%M %p` then cut ":00" and
  # downcased it; `ToolContext#friendly_future` wrote `%-I:%M%P` and cut ":00";
  # `PlungeAdvisor.format_window` wrote `%-I%P` and cut a ":00" that string
  # cannot contain - so a window starting at 8:30 went into the seed as "8am"
  # and the half hour was gone. Everything else called `strftime` in place.
  #
  # One definition, and the phrasers above delegate to it.
  #
  # A RANGE drops the first meridiem when both ends share it, which is the half
  # a reader can infer and the half that doubles the length of the thing.
  module Clock
    module_function

    # "3pm", "3:15pm"
    def at(time, zone: nil)
      local = zoned(time, zone)
      return nil if local.nil?

      minutes = (local.strftime(":%M") unless local.min.zero?)
      "#{local.strftime("%-I")}#{minutes}#{local.strftime("%P")}"
    end

    # "3-4pm" across one afternoon, "11am-1pm" across the middle of the day.
    #
    # Same-DAY as well as same-meridiem, because 3pm Monday to 3pm Tuesday is
    # not "3-3pm" - it is the one range where the shorthand would lie.
    def range(from, to, zone: nil)
      a = zoned(from, zone)
      b = zoned(to, zone)
      return at(b) if a.nil?
      return at(a) if b.nil? || a == b

      "#{shared_meridiem?(a, b) ? bare(a) : at(a)}-#{at(b)}"
    end

    # "Sat 3pm"
    def day_at(time, zone: nil)
      local = zoned(time, zone)
      return nil if local.nil?

      "#{local.strftime("%a")} #{at(local)}"
    end

    # "Sat Sep 13, 3pm"
    def date_at(time, zone: nil)
      local = zoned(time, zone)
      return nil if local.nil?

      "#{local.strftime("%a %b %-d")}, #{at(local)}"
    end

    def shared_meridiem?(first, second)
      first.to_date == second.to_date && first.strftime("%P") == second.strftime("%P")
    end

    # The digits on their own, for the near end of a range that shares its
    # meridiem with the far end.
    def bare(time)
      at(time).to_s.sub(/[ap]m\z/, "")
    end

    def zoned(time, zone)
      return nil if time.blank?

      local = (time.respond_to?(:strftime) ? time : (::Time.zone.parse(time.to_s) rescue nil))
      return nil if local.nil?
      return local if zone.blank? || !local.respond_to?(:in_time_zone)

      local.in_time_zone(zone)
    end
  end
end
