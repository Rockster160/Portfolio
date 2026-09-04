module Buddy
  # Reads Alpine's hourly forecast and produces a short block for the Today
  # briefing — but ONLY about rain. Alpine's temperature, its sky and its
  # general shape of a day are somebody else's business; the one thing that
  # decides whether the canyon is worth the drive is whether it's wet. It used
  # to speak up for heavy dark cloud as well, which is a forecast for a place
  # nobody is standing in.
  #
  # When it IS raining, it lists the rain windows and judges whether it's a good
  # day to go plunge:
  #
  #   * the rain falls during a DOWN-TIME window (late morning / early afternoon
  #     or 6-8pm on weekdays; any time on weekends),
  #   * ESPECIALLY when the agenda's clear, and
  #   * the drive there/back avoids rush hour and the glare hour just after
  #     sunrise / just before sunset.
  #
  # Everything is best-effort and production-gated through WeatherService (which
  # returns nil off-prod), so the whole block simply vanishes when there's no
  # data — the briefing never depends on it.
  module PlungeAdvisor
    module_function

    ALPINE = { lat: 40.4527, lng: -111.7688 }.freeze

    RAINY_MAINS   = %w[Rain Drizzle Thunderstorm Snow].freeze
    DRIVE_MINUTES = 30          # rough Alpine round-trip leg
    RUSH_HOURS    = [7, 8, 16, 17].freeze # leave/return we'd rather dodge

    # Daytime only, for the week ahead. Rain at 3am is not weather anybody is
    # out in, and a window running through the small hours puts a time in the
    # briefing that nothing can be done with.
    DAY_HOURS = (7..19)

    # How far "this week" reaches, counting from tomorrow.
    WEEK_DAYS = 6

    # The day-level labels worth a line. `windy` is not: a gusty Thursday says
    # nothing about whether the canyon is worth the drive.
    WET_KINDS = %w[rain snow storms].freeze

    # Returns the seed block string, or "" when there's nothing to report.
    # Today's Alpine rain, as FACTS. One line each, no instructions in them -
    # what to do with them is the briefing's business (Buddy::BriefingFacts).
    #
    # The plunge is only ever mentioned when the window is genuinely good.
    # There's no line for a bad one, because the reasons it read as bad are
    # guesses at somebody's day and came out sounding presumptuous on days that
    # were in fact wide open.
    def briefing_lines(user, now: Time.current)
      data = WeatherService.data(lat: ALPINE[:lat], lng: ALPINE[:lng])
      return [] if data.blank?

      tz = Buddy::Day.zone(user).name
      a  = analyze(data, user, tz, now)
      return [] unless a[:notable]

      lines = [a[:headline]]
      lines << "Rain in Alpine #{a[:rain_windows].join(", ")}" if a[:rain_windows].any?
      lines << "Good plunge window: #{a[:plunge_reason]}" if a[:plunge]
      lines
    end

    # Today's Alpine rain windows on their own, as the formatted strings
    # `briefing_block` puts in the seed. For Buddy::GPT::Turn, which has to
    # know what it asked for before it can tell that the briefing didn't say
    # it. Empty whenever the block itself would be.
    def today_rain_windows(user, now: Time.current)
      data = WeatherService.data(lat: ALPINE[:lat], lng: ALPINE[:lng])
      return [] if data.blank?

      a = analyze(data, user, Buddy::Day.zone(user).name, now)
      return [] unless a[:notable]

      Array(a[:rain_windows])
    end

    # Every daytime rain window in Alpine between tomorrow and the end of the
    # week. TODAY is deliberately absent: `briefing_block` above already lists
    # today's windows whenever there are any, and both blocks land in the same
    # prompt.
    #
    # Two resolutions, because the forecast has two. The hourly array runs 48
    # hours and gives real times; past its end there is one `pop` per day and
    # nothing at all about WHEN. Those days get their odds and no window rather
    # than a plausible-sounding hour.
    def week_rain_lines(user, now: Time.current)
      data = WeatherService.data(lat: ALPINE[:lat], lng: ALPINE[:lng])
      return [] if data.blank?

      tz     = Buddy::Day.zone(user).name
      first  = now.in_time_zone(tz).to_date + 1
      hourly = Array(data["hourly"]).map { |h| [Time.at(h["dt"].to_i).in_time_zone(tz), h] }
      days   = timed_days(first, hourly.last&.first)

      timed_rain(hourly, tz, days, first) + loose_rain(data, tz, days, first)
    end

    # The days the hourly forecast reaches all the way through. One it only half
    # covers falls to the day-level line instead: a real window from the morning
    # sitting next to silence about the afternoon reads as a complete answer.
    def timed_days(first, covered_through)
      return [] if covered_through.nil?

      (first..(first + WEEK_DAYS)).select { |date|
        (covered_through.to_date > date) || (covered_through.to_date == date && covered_through.hour >= DAY_HOURS.last)
      }
    end

    def timed_rain(hourly, tz, days, first)
      wet = hourly.select { |at, hour| days.include?(at.to_date) && DAY_HOURS.cover?(at.hour) && rainy?(hour) }
      contiguous_windows(wet.map(&:last), tz).map { |win| "#{day_label(win[0], first)} #{format_window(win)}" }
    end

    def loose_rain(data, tz, days, first)
      Array(data["daily"]).filter_map { |day|
        at   = Time.at(day["dt"].to_i).in_time_zone(tz)
        date = at.to_date
        next if date < first || date > (first + WEEK_DAYS) || days.include?(date)

        kind = WeatherService.day_notable(day)
        next unless WET_KINDS.include?(kind)

        "#{day_label(at, first)}, #{kind} at #{(day["pop"].to_f * 100).round}% - the forecast has no hours that far out, so the day on its own is the whole of it"
      }
    end

    # `first` is tomorrow, which is the only day here with a name of its own.
    def day_label(time, first)
      time.to_date == first ? "tomorrow" : time.strftime("%A")
    end

    # ---- analysis ----

    def analyze(data, user, tz, now)
      local_now = now.in_time_zone(tz)
      today     = Buddy::Day.today(user, now: now) # perceived day (3am rollover)

      # FUTURE weather only — an hour bucket still counts if it hasn't fully
      # elapsed. Rain that already fell isn't worth a mention (and keeps the
      # block from reporting a stale forecast late in the day).
      hours = today_hours(data["hourly"], tz, today).select { |h|
        (Time.at(h["dt"].to_i).in_time_zone(tz) + 3600) > local_now
      }
      rain = hours.select { |h| rainy?(h) }
      return { notable: false } if rain.empty?

      windows = contiguous_windows(rain, tz)
      sun     = sun_times(data, tz, today)

      plunge, reason = assess_plunge(windows, user, tz, today, local_now, sun)

      {
        notable:       true,
        headline:      headline(rain),
        rain_windows:  windows.map { |w| format_window(w) },
        plunge:        plunge,
        plunge_reason: reason,
      }
    end

    def today_hours(hourly, tz, today)
      Array(hourly).select { |h|
        (Buddy::Day.perceived_date(Time.at(h["dt"].to_i).in_time_zone(tz)) == today) rescue false
      }
    end

    def rainy?(hour)
      main = hour.dig("weather", 0, "main").to_s
      RAINY_MAINS.include?(main) || hour.key?("rain") || hour.key?("snow")
    end

    def headline(rain)
      snow = rain.any? { |h| h.dig("weather", 0, "main").to_s == "Snow" || h.key?("snow") }
      snow ? "Snow moving through Alpine today." : "Rain in the forecast for Alpine today."
    end

    # Group consecutive rain hours into [start_local, end_local] windows.
    def contiguous_windows(rain_hours, tz)
      times = rain_hours.map { |h| Time.at(h["dt"].to_i).in_time_zone(tz) }.sort
      return [] if times.empty?

      windows = []
      run_start = times.first
      prev = times.first
      times[1..].each do |t|
        if (t - prev) > 3600 + 60 # gap > 1h → new window
          windows << [run_start, prev + 3600]
          run_start = t
        end
        prev = t
      end
      windows << [run_start, prev + 3600]
      windows
    end

    def format_window(win)
      fmt = ->(t) { t.strftime("%-I%P").sub(":00", "") }
      "#{fmt.call(win[0])}-#{fmt.call(win[1])}"
    end

    def sun_times(data, tz, today)
      day = Array(data["daily"]).find { |d| (Buddy::Day.perceived_date(Time.at(d["dt"].to_i).in_time_zone(tz)) == today) rescue false }
      day ||= data["current"] || {}
      {
        sunrise: (Time.at(day["sunrise"].to_i).in_time_zone(tz) if day["sunrise"]),
        sunset:  (Time.at(day["sunset"].to_i).in_time_zone(tz) if day["sunset"]),
      }
    end

    # ---- plunge decision ----

    # Returns [true, reason] only when a future rain window genuinely lines up:
    # a down-time band, agenda clear then, drive dodges rush hour + glare. When
    # nothing qualifies we return [false, nil] and say nothing about the plunge -
    # no negative editorializing (see briefing_block).
    def assess_plunge(windows, user, tz, today, local_now, sun)
      weekend = today.saturday? || today.sunday?

      windows.each do |win|
        next if win[1] <= local_now # already past
        next unless downtime?(win, weekend)
        next unless agenda_clear?(user, tz, win)
        next unless drive_windows_ok?(win, sun)

        reason = "rain lands #{format_window(win)}, a #{weekend ? "weekend" : "weekday"} down-time, your day's clear then, and the drive dodges rush hour and sun glare"
        return [true, reason]
      end

      [false, nil]
    end

    # Any hour of the window falls in a down-time band: late morning / early
    # afternoon (11am-3pm) or early evening (6-8pm) on a weekday; any hour on a
    # weekend.
    def downtime?(win, weekend)
      hours = (win[0].hour..(win[1] - 1).hour)
      return true if weekend

      hours.any? { |h| (11..14).cover?(h) || (18..19).cover?(h) }
    end

    def agenda_clear?(user, _tz, win)
      agenda_ids = Agenda.where(user_id: user.id).pluck(:id)
      return true if agenda_ids.empty?

      buffer_start = (win[0] - 45.minutes).utc
      buffer_end   = (win[1] + 45.minutes).utc
      # All-day rows are excluded, the same way the travel chain and the
      # collision check exclude them. An all-day item runs local midnight to
      # midnight, so it overlaps EVERY window on its date - one birthday on the
      # calendar and the whole day reads as booked, which is how a plunge stops
      # being suggested for reasons nobody can see. It says what date it is, not
      # that an hour of it is spoken for.
      AgendaItem.where(agenda_id: agenda_ids)
        .where.not(status: :cancelled)
        .where(all_day: [false, nil])
        .where("start_at < ? AND (end_at IS NULL OR end_at > ?)", buffer_end, buffer_start)
        .none?
    end

    # The leave (before) and return (after) drives should miss rush hour and the
    # hour after sunrise / hour before sunset.
    def drive_windows_ok?(win, sun)
      leave  = win[0] - DRIVE_MINUTES.minutes
      back   = win[1] + DRIVE_MINUTES.minutes
      [leave, back].none? { |t| RUSH_HOURS.include?(t.hour) || glare?(t, sun) }
    end

    def glare?(time, sun)
      sr = sun[:sunrise]
      ss = sun[:sunset]
      return true if sr && time >= sr && time <= sr + 1.hour
      return true if ss && time >= ss - 1.hour && time <= ss

      false
    end
  end
end
