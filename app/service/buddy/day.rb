module Buddy
  # The app-wide "today" boundary, in one place. The whole app (Chores /
  # Dailies, agenda default-date) rolls the day over at 3am, NOT midnight —
  # see User#perceived_today. Buddy must agree, or "Today" and the Dailies
  # disagree between midnight and 3am ("is this today or tomorrow?").
  #
  # User#perceived_today reads the real clock; these helpers also accept an
  # explicit `now` so schedulers/advisors that reason about a passed-in time
  # (and specs) get the same rollover applied to THAT time.
  module Day
    ROLLOVER_HOUR = 3

    module_function

    # The perceived date for a local time (before 3am counts as the day before).
    def perceived_date(local_time)
      d = local_time.to_date
      d -= 1 if local_time.hour < ROLLOVER_HOUR
      d
    end

    def zone(user)
      ActiveSupport::TimeZone[user.timezone.presence || "America/Denver"] || Time.zone
    end

    # The user's perceived "today" (right now, or at `now`).
    def today(user, now: nil)
      perceived_date((now || Time.current).in_time_zone(zone(user)))
    end

    # [start, end) Times of a perceived day: 3am local to 3am local next day.
    # Defaults to the user's perceived today (optionally anchored to `now`).
    def range(user, date: nil, now: nil)
      z = zone(user)
      date ||= today(user, now: now)
      start = z.local(date.year, date.month, date.day, ROLLOVER_HOUR)
      [start, start + 1.day]
    end

    # A local time on a perceived date, e.g. the 8:30am fallback fire time.
    def at(user, hour:, min: 0, date: nil, now: nil)
      z = zone(user)
      date ||= today(user, now: now)
      z.local(date.year, date.month, date.day, hour, min)
    end
  end
end
