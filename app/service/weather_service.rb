# Fetches + formats compact weather for chat surfaces (Buddy's Today briefing,
# the check_weather tool, the byte_weather endpoint). The parsed payload is
# cached ~15 min so we never bill OpenWeather per turn - weather doesn't move
# faster than the dashboard's own 10-minute refresh, and one fetch feeds both
# the current summary and the week outlook. Never raises: returns nil on any
# failure so a weather hiccup can't break a Buddy turn.
module WeatherService
  module_function

  # Home coords the dashboard already uses.
  HOME_LAT  = 40.4805
  HOME_LNG  = -111.9982
  CACHE_TTL = 15.minutes

  # How old the shared forecast may be before we stop trusting it and fetch our
  # own. Generous next to the Weather Refresh task's hourly cadence, so one
  # missed run doesn't cost a billed fetch - but a feeder that has actually
  # stopped doesn't leave Buddy quoting yesterday's weather either.
  SHARED_TTL = 3.hours

  # Cached, parsed onecall payload (or nil). Match the AddressBook/traveltime
  # convention: never bill an external API from dev/test.
  def data(lat: HOME_LAT, lng: HOME_LNG, user: nil)
    shared(lat, lng, user) || own(lat, lng)
  end

  # The forecast the hourly Weather Refresh task already fetched. Reading it
  # costs nothing and bills nobody, so it comes first and works in every
  # environment - and it means Buddy, Jil and the dashboard are all quoting the
  # same numbers instead of three independently-timed fetches.
  #
  # Home only: the cache holds one location, and a named place still has to be
  # looked up.
  def shared(lat, lng, user)
    return nil unless home?(lat, lng)

    cache = (user || ::User.me)&.caches&.dig(:weather)
    return nil if cache.blank?

    fetched_at = cache[:fetched_at].presence&.then { |at| ::Time.zone.parse(at.to_s) }
    return nil if fetched_at.nil? || fetched_at < SHARED_TTL.ago

    cache[:forecast].presence&.deep_stringify_keys
  rescue StandardError => e
    Rails.logger.warn("[WeatherService] shared read: #{e.class}: #{e.message}")
    nil
  end

  def own(lat, lng)
    return nil unless Rails.env.production?

    key = ENV["WEATHER_APIKEY"].to_s
    return nil if key.empty?

    Rails.cache.fetch("weather_data(#{lat.round(2)},#{lng.round(2)})", expires_in: CACHE_TTL) {
      fetch(lat, lng, key)
    }
  rescue StandardError => e
    Rails.logger.warn("[WeatherService] #{e.class}: #{e.message}")
    nil
  end

  def home?(lat, lng)
    lat.to_f.round(2) == HOME_LAT.round(2) && lng.to_f.round(2) == HOME_LNG.round(2)
  end

  # One-line current + today read ("currently 72°F, clear. today high 88 / low 61.").
  def summary(lat: HOME_LAT, lng: HOME_LNG, user: nil)
    payload = data(lat: lat, lng: lng, user: user)
    payload && format_summary(payload)
  end

  # Short list of the notable-weather days coming this week ("rain Tue & Thu,
  # windy Fri"), or nil if the week's unremarkable. Not a full forecast - just
  # the days worth a heads-up.
  def week_outlook(lat: HOME_LAT, lng: HOME_LNG, user: nil)
    payload = data(lat: lat, lng: lng, user: user)
    payload && format_week_outlook(payload)
  end

  def fetch(lat, lng, key)
    uri = URI("https://api.openweathermap.org/data/3.0/onecall")
    uri.query = URI.encode_www_form(
      lat:     lat,
      lon:     lng,
      units:   :imperial,
      # Keep `hourly` — Buddy's plunge advisor reads per-hour rain timing +
      # cloud cover from it (Buddy::PlungeAdvisor). `current` + `daily` still
      # power summary/week_outlook; hourly is additive.
      exclude: "minutely,alerts",
      lang:    :en,
      appid:   key,
    )
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |http|
      http.get(uri.request_uri)
    }
    return nil unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)
  end

  def format_summary(payload)
    cur   = payload["current"] || {}
    today = (payload["daily"] || []).first || {}
    cond  = (cur.dig("weather", 0, "description") || "").to_s
    temp  = cur["temp"].to_f.round
    feels = cur["feels_like"].to_f.round
    hi    = today.dig("temp", "max").to_f.round
    lo    = today.dig("temp", "min").to_f.round
    rain  = (today["pop"].to_f * 100).round

    now = "currently #{temp}°F"
    now += ", #{cond}" unless cond.empty?
    parts = [now]
    parts << "feels like #{feels}°F" if (feels - temp).abs >= 3
    parts << "today high #{hi}°F / low #{lo}°F"
    parts << "chance of rain #{rain}%" if rain.positive?
    parts.join(". ") + "."
  end

  # Scan the next ~6 days for anything worth flagging, grouped by kind so it
  # reads naturally ("rain Tue & Thu, windy Fri"). Day names are in the
  # forecast location's own timezone (onecall's `timezone_offset`).
  def format_week_outlook(payload)
    offset = payload["timezone_offset"].to_i
    days   = Array(payload["daily"])[1, 6] || []

    groups = Hash.new { |h, k| h[k] = [] }
    days.each do |d|
      kind = day_notable(d)
      next unless kind

      groups[kind] << Time.at(d["dt"].to_i + offset).utc.strftime("%a")
    end
    return nil if groups.empty?

    # Most notable first.
    %w[snow storms rain windy].filter_map { |kind|
      "#{kind} #{join_days(groups[kind])}" if groups[kind].any?
    }.join(", ")
  end

  # The single most-notable label for a day, or nil. Precip beats wind.
  def day_notable(day)
    main = day.dig("weather", 0, "main").to_s
    pop  = day["pop"].to_f
    gust = [day["wind_gust"].to_f, day["wind_speed"].to_f].max

    return "snow"   if main == "Snow"
    return "storms" if main == "Thunderstorm"
    return "rain"   if %w[Rain Drizzle].include?(main) || pop >= 0.3
    return "windy"  if gust >= 30

    nil
  end

  def join_days(names)
    names = names.uniq
    return names.first if names.size <= 1

    "#{names[0..-2].join(", ")} & #{names[-1]}"
  end
end
