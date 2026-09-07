Buddy::Tools.register(
  name:        :check_weather,
  description: <<~TXT,
    Look up the current weather + today's high/low for a place, then tell the
    person about it in your own words. Use whenever they ask about the weather,
    whether to bring a jacket, if it'll rain, how hot it'll get, etc.

    `location` is OPTIONAL:
      - omit it for home / local weather ("what's it like out?").
      - pass a place for anywhere else - a saved spot ("the gym"), an
        appointment location ("TMS"), or a general place / city ("Moab",
        "Salt Lake"). It resolves saved places first, then looks the place up.

    Home is a FIXED point and nothing here can move it. If they say the forecast
    is for the wrong town, say plainly that home weather comes from one set
    location you can't change from a chat, tell them which place you were
    actually reading, and offer `request_feature`. Prod 5513: told "I don't live
    in Alpine! We live in Herriman!", the answer was "I've got it corrected now,
    and I'll stick to Herriman for your weather from here on out" - nothing was
    corrected, nothing was recorded, and the Alpine line had come from a
    briefing repair rather than from anybody's location.

    The reading comes straight back to you in this same turn, so tell them right
    away rather than saying you'll go peek - warm and brief, factoring in
    whatever they were asking about (biking, a jacket, rain timing). Don't
    invent numbers, and don't recite a raw forecast.
  TXT
  args:        {
    location: { type: :string, required: false, description: "Place to check; omit for home / local weather" },
  },
  confirm:     ->(payload, ctx) {
    place = ctx.resolve_weather_place(payload[:location])
    { summary: "Weather for #{place["label"]}", resolved: place }
  },
  label:       ->(payload, _ctx) { "Weather · #{payload[:label] || payload["label"] || "home"}" },
  auto:        true,
  answers:     true,
  execute:     ->(payload, ctx) {
    lat     = payload[:lat] || payload["lat"]
    lng     = payload[:lng] || payload["lng"]
    label   = payload[:label] || payload["label"] || "there"
    summary = lat && lng ? WeatherService.summary(lat: lat.to_f, lng: lng.to_f, user: ctx.user) : nil

    raise "the weather service didn't answer for #{label}" if summary.to_s.strip.empty?

    {
      place:   label,
      reading: summary,
      how:     "Tell them in your own words - warm and brief - factoring in whatever they were " \
               "asking about. Don't recite the raw numbers as a list.",
    }
  },
)
