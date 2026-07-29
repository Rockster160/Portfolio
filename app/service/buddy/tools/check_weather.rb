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

    It runs on its own (no confirmation), fetches the reading, and comes BACK to
    you so you relay it conversationally. So in THIS reply just give a short
    lead-in ("let me peek") - the actual weather lands in your NEXT reply, phrased
    naturally. Don't invent numbers, and don't recite a raw forecast.
  TXT
  args:        {
    location: { type: :string, required: false, description: "Place to check; omit for home / local weather" },
  },
  confirm:     ->(payload, ctx) {
    place = ctx.resolve_weather_place(payload[:location])
    { summary: "Weather for #{place["label"]}", resolved: place }
  },
  label:       ->(payload, _ctx) { "Weather · #{payload[:label] || payload["label"] || "home"}" },
  # Level 1 (auto): a read, no confirmation. But instead of dumping a raw chip,
  # it feeds the reading back into a fresh Buddy turn so Buddy answers in its own
  # voice (a real "look it up, then respond" flow, not preloaded context).
  auto:        true,
  execute:     ->(payload, ctx) {
    lat   = payload[:lat] || payload["lat"]
    lng   = payload[:lng] || payload["lng"]
    label = payload[:label] || payload["label"] || "there"
    summary = lat && lng ? WeatherService.summary(lat: lat.to_f, lng: lng.to_f) : nil

    relayed = summary.present? && !ctx.conversation.nil?
    if relayed
      Buddy::CompanionDelivery.deliver_prompt(
        user:         ctx.user,
        conversation: ctx.conversation,
        seed:         "You just checked the weather for #{label} and it came back: #{summary}\n\nNow tell the person in your own words - warm and brief - factoring in whatever they were asking about (biking, a jacket, rain timing). Don't recite the raw numbers as a list, and don't look it up again.",
        metadata:     { "kind" => "buddy_trigger", "hidden" => true, "source" => "weather_lookup" },
      )
    end
    { label: label, summary: summary, relayed: relayed }
  },
  # Return nil when Buddy will relay it itself → ProposalBuilder skips the chip.
  # Only chip on failure, so the person still gets a reason.
  receipt:     ->(result, _ctx) {
    next nil if result[:relayed]

    result[:summary].to_s.strip.empty? ? "Couldn't pull the weather for #{result[:label]} right now." : nil
  },
)
