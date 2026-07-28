# Fetches + formats a compact current-weather one-liner for chat surfaces
# (Buddy's live context, the byte_weather endpoint). Cached ~15 min so we
# never bill OpenWeather per turn - weather doesn't move faster than the
# dashboard's own 10-minute refresh. Never raises: returns nil on any
# failure so a weather hiccup can't break a Buddy turn.
module WeatherService
  module_function

  # Home coords the dashboard already uses. No per-location support yet.
  HOME_LAT  = 40.4805
  HOME_LNG  = -111.9982
  CACHE_TTL = 15.minutes

  def summary(lat: HOME_LAT, lng: HOME_LNG)
    # Match the AddressBook/traveltime convention: never bill an external API
    # from dev/test. Prod (the live PWA) is the surface that matters.
    return nil unless Rails.env.production?

    key = ENV["WEATHER_APIKEY"].to_s
    return nil if key.empty?

    Rails.cache.fetch("weather_summary(#{lat.round(2)},#{lng.round(2)})", expires_in: CACHE_TTL) {
      payload = fetch(lat, lng, key)
      payload && format_summary(payload)
    }
  rescue => e
    Rails.logger.warn("[WeatherService] #{e.class}: #{e.message}")
    nil
  end

  def fetch(lat, lng, key)
    uri = URI("https://api.openweathermap.org/data/3.0/onecall")
    uri.query = URI.encode_www_form(
      lat:     lat,
      lon:     lng,
      units:   :imperial,
      exclude: "minutely,hourly,alerts",
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
end
