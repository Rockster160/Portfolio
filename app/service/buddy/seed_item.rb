module Buddy
  # Whether some text names one of the agenda items a briefing seed carried.
  module SeedItem
    module_function

    # A start time as `Buddy::Context` writes one: "12:00 PM", "9:30 AM".
    # `all_day` items carry the word "today" here instead and match nothing.
    TIME_RX = /\A(?<hour>\d{1,2}):(?<min>\d{2})\s*(?<mer>[ap])\.?m\.?\z/i

    # Did the text name this item?
    #
    # The title as written is the first test, because that is how a briefing
    # says one - it reads the name off the same field. It doesn't always,
    # though, and the substring test has no give at all: a briefing writes
    # "chai pickup at 12:00 PM" for an item titled "Pick up chai from LOC",
    # so a 34-minute drive and an 11:21 walk-out were never a candidate. The
    # SHS item beside it got its figures only because the model happened to
    # type that title verbatim.
    #
    # So the item's own start time counts as naming it. Every briefing that
    # names an item prints its clock time, and the thing this guard exists to
    # prevent - a leave-by for something the message never mentioned - can't
    # happen when that item's time is already in the body.
    def named_in?(body, item)
      title = item[:title].to_s.strip
      return true if title.length >= 2 && body.downcase.include?(title.downcase)

      time_said?(body, item[:time])
    end

    # Any of the seed's items, today's or the week's.
    def any_named_in?(body, facts)
      items = Array(facts[:today]) + Array(facts[:week])
      items.any? { |item| item.is_a?(::Hash) && named_in?(body, item) }
    end

    # In any of the ways a person writes that time back: "12:00 PM", "12 PM",
    # "12pm", "12 p.m.". The minutes are optional only on the hour, so 12:30
    # never satisfies 12:00.
    def time_said?(body, time)
      parts = TIME_RX.match(time.to_s.strip)
      return false if parts.nil?

      minutes = parts[:min] == "00" ? "(?::00)?" : "(?::#{parts[:min]})"
      body.match?(/(?<!\d)#{parts[:hour]}#{minutes}\s*#{parts[:mer]}\.?m\.?/i)
    end
  end
end
