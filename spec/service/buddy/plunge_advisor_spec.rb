require "rails_helper"

# The plunge advisor reads Alpine's hourly forecast and only speaks up for
# rain/snow or heavy clouds, judging whether it's a good day to plunge.
RSpec.describe Buddy::PlungeAdvisor do
  let(:user) { create(:user) }
  let(:tz)   { ActiveSupport::TimeZone["America/Denver"] }

  before { allow(user).to receive(:timezone).and_return("America/Denver") }

  # Build an onecall-shaped payload: rain during the given local hours on a day.
  def payload(day:, rain_hours: [], cloud_hours: {}, sunrise: 6, sunset: 20)
    hourly = (0..23).map { |h|
      local = tz.parse("#{day} #{format("%02d", h)}:00")
      entry = { "dt" => local.to_i, "clouds" => cloud_hours[h] || 5, "weather" => [{ "main" => "Clear" }] }
      if rain_hours.include?(h)
        entry["weather"] = [{ "main" => "Rain" }]
        entry["rain"] = { "1h" => 1.2 }
      end
      entry
    }
    noon = tz.parse("#{day} 12:00")
    {
      "hourly" => hourly,
      "daily"  => [{ "dt" => noon.to_i, "sunrise" => tz.parse("#{day} #{sunrise}:00").to_i, "sunset" => tz.parse("#{day} #{sunset}:00").to_i }],
    }
  end

  it "stays silent when there's no rain and clouds are light" do
    allow(WeatherService).to receive(:data).and_return(payload(day: "2026-07-28"))
    expect(described_class.briefing_block(user, now: tz.parse("2026-07-28 07:00"))).to eq("")
  end

  it "reports rain windows when it's going to rain" do
    allow(WeatherService).to receive(:data).and_return(payload(day: "2026-07-28", rain_hours: [12, 13]))
    block = described_class.briefing_block(user, now: tz.parse("2026-07-28 07:00"))
    expect(block).to include("Rain in the forecast").and include("12pm-2pm")
  end

  it "calls it a good plunge day when weekday rain lands in a down-time with a clear agenda" do
    # Tuesday 2026-07-28; rain noon-2pm (down-time), sunrise 6 / sunset 20 so no
    # glare, drives at ~11:30 and ~2:30 miss rush hour.
    allow(WeatherService).to receive(:data).and_return(payload(day: "2026-07-28", rain_hours: [12, 13]))
    block = described_class.briefing_block(user, now: tz.parse("2026-07-28 07:00"))
    expect(block).to include("Good plunge window")
  end

  it "says NOTHING about the plunge (no negative claim) when the agenda conflicts" do
    agenda = Agenda.create!(user: user, name: "Mine")
    AgendaItem.create!(
      agenda: agenda, name: "Meeting", kind: :event,
      start_at: tz.parse("2026-07-28 12:00"), end_at: tz.parse("2026-07-28 13:00")
    )
    allow(WeatherService).to receive(:data).and_return(payload(day: "2026-07-28", rain_hours: [12, 13]))

    block = described_class.briefing_block(user, now: tz.parse("2026-07-28 07:00"))
    expect(block).to include("Rain in the forecast") # still reports the rain
    expect(block).not_to include("plunge")           # but no plunge editorializing
  end

  # An all-day row runs local midnight to midnight, so it overlaps EVERY window
  # on its date. One birthday on the calendar and the whole day read as booked,
  # which is how the plunge stopped being suggested for a reason nobody could
  # see. The travel chain and the collision check both already exclude them.
  it "does not let an all-day row book the whole day out" do
    agenda = Agenda.create!(user: user, name: "Mine")
    AgendaItem.create!(
      agenda: agenda, name: "Marcos' Birthday", kind: :event, all_day: true,
      start_at: tz.parse("2026-07-28 00:00"), end_at: tz.parse("2026-07-29 00:00")
    )
    allow(WeatherService).to receive(:data).and_return(payload(day: "2026-07-28", rain_hours: [12, 13]))

    block = described_class.briefing_block(user, now: tz.parse("2026-07-28 07:00"))
    expect(block).to include("Good plunge window")
  end

  # Alpine is here for one question and it's whether the canyon is wet. A
  # forecast of dark cloud over a place nobody is standing in used to open the
  # block; it says nothing about the drive.
  it "stays quiet about heavy dark cloud with no rain under it" do
    clouds = { 10 => 90, 11 => 88, 12 => 85 }
    allow(WeatherService).to receive(:data).and_return(payload(day: "2026-07-28", cloud_hours: clouds))

    expect(described_class.briefing_block(user, now: tz.parse("2026-07-28 07:00"))).to eq("")
  end

  it "still opens on the rain when there is some" do
    allow(WeatherService).to receive(:data).and_return(payload(day: "2026-07-28", rain_hours: [12, 13]))

    expect(described_class.briefing_block(user, now: tz.parse("2026-07-28 07:00"))).to include("RAIN IN ALPINE TODAY")
  end

  # The week ahead, which is a different question from today's plunge window and
  # answered at two different resolutions: real hours for as far as the hourly
  # forecast reaches, and odds alone past that.
  describe ".week_rain_block" do
    let(:now) { tz.parse("2026-08-20 07:00") } # a Thursday

    # `rain_at` and `daily_rain` are keyed by local date. `hours` decides how far
    # the hourly array reaches, which is the whole point of several of these.
    def week_payload(from: "2026-08-20 00:00", hours: 48, rain_at: {}, daily_rain: {})
      start  = tz.parse(from)
      hourly = (0...hours).map { |i|
        local = start + i.hours
        wet   = Array(rain_at[local.strftime("%Y-%m-%d")]).include?(local.hour)
        entry = { "dt" => local.to_i, "clouds" => 5, "weather" => [{ "main" => wet ? "Rain" : "Clear" }] }
        entry["rain"] = { "1h" => 1.0 } if wet
        entry
      }
      daily = (0..7).map { |i|
        noon = start.beginning_of_day + i.days + 12.hours
        pop  = daily_rain[noon.strftime("%Y-%m-%d")]
        { "dt" => noon.to_i, "pop" => (pop || 0) / 100.0, "weather" => [{ "main" => pop ? "Rain" : "Clear" }] }
      }
      { "hourly" => hourly, "daily" => daily }
    end

    def block(**args)
      allow(WeatherService).to receive(:data).and_return(week_payload(**args))
      described_class.week_rain_block(user, now: now)
    end

    it "gives tomorrow's rain as hours, not as a day" do
      expect(block(rain_at: { "2026-08-21" => [13, 14, 15] })).to include("tomorrow 1pm-4pm")
    end

    it "names a further day by weekday" do
      expect(block(hours: 72, rain_at: { "2026-08-22" => [10, 11] })).to include("Saturday 10am-12pm")
    end

    # Today already has a block of its own directly above this one in the seed,
    # and two lists of the same windows is how a briefing ends up saying it twice.
    it "leaves today alone" do
      expect(block(rain_at: { "2026-08-20" => [13, 14] })).to eq("")
    end

    it "ignores rain nobody would be out in" do
      expect(block(rain_at: { "2026-08-21" => [2, 3, 4] })).to eq("")
    end

    # Past 48 hours the forecast has one `pop` per day and nothing about when.
    # An invented afternoon would be the one failure worse than saying less.
    it "gives odds and no time once the hours run out" do
      out = block(daily_rain: { "2026-08-24" => 60 })

      expect(out).to include("Monday, rain at 60%")
      expect(out).to include("no hours that far out")
      expect(out).not_to match(/\d+[ap]m-/)
    end

    # A day the hourly array only half covers would otherwise get a real morning
    # window and silence about the afternoon, which reads as the whole answer.
    it "hands a half-covered day to the day-level line rather than splitting it" do
      out = block(
        hours:      34, # through 2026-08-21 09:00
        rain_at:    { "2026-08-21" => [8] },
        daily_rain: { "2026-08-21" => 70 },
      )

      expect(out).to include("tomorrow, rain at 70%")
      expect(out).not_to include("8am")
    end

    it "says nothing when the week is dry" do
      expect(block).to eq("")
    end

    it "asks for the hours" do
      expect(block(rain_at: { "2026-08-21" => [13] })).to include("Give the hours wherever there are hours")
    end

    # Same rule as the weather block above: a phrase written down so it can be
    # forbidden is a phrase the model has been handed.
    it "names nothing it doesn't want said" do
      expect(block(rain_at: { "2026-08-21" => [13] })).not_to match(/what to wear|don't|do not|never/i)
    end
  end

  # Alpine is a canyon he drives to. Nobody else in the house has a reason to
  # hear a forecast for a town half an hour away.
  describe "who gets the Alpine week" do
    let(:wet) {
      hourly = (0..47).map { |i|
        local = tz.parse("2026-08-20 00:00") + i.hours
        wet   = local.to_date == Date.new(2026, 8, 21) && local.hour == 13
        entry = { "dt" => local.to_i, "clouds" => 5, "weather" => [{ "main" => wet ? "Rain" : "Clear" }] }
        entry["rain"] = { "1h" => 1.0 } if wet
        entry
      }
      { "hourly" => hourly, "daily" => [] }
    }

    before { allow(WeatherService).to receive(:data).and_return(wet) }

    it "reaches him" do
      travel_to(tz.parse("2026-08-20 07:00")) do
        expect(Buddy::TodayBriefing.alpine_week_block(User.me)).to include("RAIN IN ALPINE")
      end
    end

    it "does not reach anybody else" do
      travel_to(tz.parse("2026-08-20 07:00")) do
        expect(Buddy::TodayBriefing.alpine_week_block(user)).to eq("")
      end
    end
  end
end
