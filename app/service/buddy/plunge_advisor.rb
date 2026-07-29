module Buddy
  # Reads Alpine's hourly forecast and produces a short block for the Today
  # briefing — but ONLY when there's something worth saying: rain/snow, or heavy
  # dark clouds. When it IS raining, it lists the rain windows and judges
  # whether it's a good day to go plunge:
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
    HEAVY_CLOUDS  = 80          # % cover that reads as "dark/heavy"
    DRIVE_MINUTES = 30          # rough Alpine round-trip leg
    RUSH_HOURS    = [7, 8, 16, 17].freeze # leave/return we'd rather dodge

    # Returns the seed block string, or "" when there's nothing to report.
    def briefing_block(user, now: Time.current)
      data = WeatherService.data(lat: ALPINE[:lat], lng: ALPINE[:lng])
      return "" if data.blank?

      tz = user.timezone.presence || "America/Denver"
      a  = analyze(data, user, tz, now)
      return "" unless a[:notable]

      lines = ["", "ALPINE WEATHER (only surfaced because there's something to note - otherwise stay quiet on weather):"]
      lines << "- #{a[:headline]}"
      lines << "- Rain windows today (give these times): #{a[:rain_windows].join(", ")}" if a[:rain_windows].any?
      # ONLY speak up about the plunge when it's genuinely a good window. If it's
      # not, say NOTHING about plunging - don't editorialize about why not (a
      # "you're too busy" claim reads as presumptuous when the day's actually
      # clear). Just report the rain and move on.
      if a[:plunge]
        lines << "- Good plunge window: #{a[:plunge_reason]}. Float the plunge lightly (don't oversell it), and DON'T claim they're busy or the day's packed."
      end
      lines.join("\n")
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
      rain  = hours.select { |h| rainy?(h) }
      heavy = hours.select { |h| h["clouds"].to_i >= HEAVY_CLOUDS }

      notable = rain.any? || heavy.size >= 3
      return { notable: false } unless notable

      windows = contiguous_windows(rain, tz)
      sun     = sun_times(data, tz, today)

      plunge, reason = assess_plunge(windows, user, tz, today, local_now, sun)

      {
        notable:       true,
        headline:      headline(rain, heavy),
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

    def headline(rain, _heavy)
      if rain.any?
        snow = rain.any? { |h| h.dig("weather", 0, "main").to_s == "Snow" || h.key?("snow") }
        snow ? "Snow moving through Alpine today." : "Rain in the forecast for Alpine today."
      else
        "Heavy, dark cloud cover over Alpine today."
      end
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
      AgendaItem.where(agenda_id: agenda_ids)
        .where.not(status: :cancelled)
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
