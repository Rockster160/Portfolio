Buddy::Tools.register(
  name:        :check_weather,
  description: <<~TXT,
    Look up the current weather + today's high/low for a place. Use whenever
    the person asks about the weather, whether to bring a jacket, if it'll
    rain, how hot it'll get, etc.

    `location` is OPTIONAL:
      - omit it for home / local weather ("what's it like out?").
      - pass a place for anywhere else - a saved spot ("the gym"), an
        appointment location ("TMS"), or a general place or city
        ("the Plunge in Alpine", "Moab", "Salt Lake"). It resolves saved
        places first, then falls back to looking the place up.

    Runs on its own (no confirmation) and drops the reading into the thread,
    so a short lead-in like "let me peek" is all you need - don't invent
    numbers yourself.
  TXT
  args: {
    location: { type: :string, required: false, description: "Place to check; omit for home / local weather" },
  },
  confirm: ->(payload, ctx) {
    place = ctx.resolve_weather_place(payload[:location])
    { summary: "Weather for #{place["label"]}", resolved: place }
  },
  label:   ->(payload, _ctx) { "Weather · #{payload[:label] || payload["label"] || "home"}" },
  execute: ->(payload, _ctx) {
    lat   = payload[:lat] || payload["lat"]
    lng   = payload[:lng] || payload["lng"]
    label = payload[:label] || payload["label"] || "there"
    summary = lat && lng ? WeatherService.summary(lat: lat.to_f, lng: lng.to_f) : nil
    { label: label, summary: summary }
  },
  # Weather is a read - no confirmation checkbox; it runs and posts the result.
  auto:    true,
  receipt: ->(result, _ctx) {
    if result[:summary].to_s.strip.empty?
      "Couldn't pull the weather for #{result[:label]} right now."
    else
      "🌤️ #{result[:label]}: #{result[:summary]}"
    end
  },
)
