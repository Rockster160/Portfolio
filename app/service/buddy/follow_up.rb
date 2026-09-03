module Buddy
  # When one thing has to start after another finishes.
  #
  # Back-to-back is not a real plan. Something ends at 1:31 and the next thing
  # starts at 1:31 only on a calendar; in a house there is a car to park, a coat
  # to take off, a dog at the door. So a follow-on gets a breath, and then it
  # gets a time a person would actually say.
  #
  # `after(1:31)` → **1:40**. Not 1:36, which is what the arithmetic gives and
  # nobody would ever propose out loud.
  #
  # Two rules, in order:
  #
  #   1. At least LEEWAY (5 minutes) after the thing it follows.
  #   2. Then up to the next time on the clock people speak in — the tens and
  #      the quarters. Landing exactly on one is fine; it already satisfies both.
  #
  # In practice that gives 5-15 minutes of room, which is the range asked for.
  # It never gives less than 5 and never rounds DOWN, because the whole point is
  # not to be arriving somewhere while still leaving somewhere else.
  module FollowUp
    module_function

    LEEWAY = 5.minutes

    # :00 :10 :15 :20 :30 :40 :45 :50 — every ten, plus the quarters that fall
    # between them. Deliberately not every five: :35 and :55 are arithmetic
    # rather than times anybody suggests.
    SLOTS = [0, 10, 15, 20, 30, 40, 45, 50].freeze

    def after(time, leeway: LEEWAY)
      return nil if time.blank?

      earliest = time + leeway
      # Seconds are noise from an epoch computed off a drive time; a slot is a
      # whole minute and anything past it has already overshot.
      earliest += 1.minute if earliest.sec.positive?
      round_up(earliest.change(sec: 0))
    end

    def round_up(time)
      slot = SLOTS.find { |m| m >= time.min }
      return time.change(min: slot) if slot

      # Past :50 — the next slot is the top of the following hour.
      time.change(min: 0) + 1.hour
    end
  end
end
