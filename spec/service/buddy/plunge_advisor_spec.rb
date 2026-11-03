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

  def lines_for(**args)
    allow(WeatherService).to receive(:data).and_return(payload(day: "2026-07-28", **args))
    described_class.briefing_lines(user, now: tz.parse("2026-07-28 07:00"))
  end

  # Alpine is here for one question, whether the canyon is wet, so dark cloud
  # with no rain under it says nothing.
  it "stays silent when there's no rain, however cloudy", :aggregate_failures do
    expect(lines_for).to be_empty
    expect(lines_for(cloud_hours: { 10 => 90, 11 => 88, 12 => 85 })).to be_empty
  end

  # Tuesday 2026-07-28; rain noon-2pm (down-time), sunrise 6 / sunset 20 so no
  # glare, drives at ~11:30 and ~2:30 miss rush hour.
  it "reports the rain window and offers a plunge when it lands in a clear down-time", :aggregate_failures do
    lines = lines_for(rain_hours: [12, 13])

    expect(lines.join("\n")).to include("12-2pm", described_class::PLUNGE_PREFIX)
    expect(described_class.plunge_offered?(lines)).to be(true)
  end

  it "reports the rain but says nothing about the plunge when the agenda conflicts", :aggregate_failures do
    agenda = Agenda.create!(user: user, name: "Mine")
    AgendaItem.create!(
      agenda: agenda, name: "Meeting", kind: :event,
      start_at: tz.parse("2026-07-28 12:00"), end_at: tz.parse("2026-07-28 13:00")
    )

    lines = lines_for(rain_hours: [12, 13])

    expect(lines.join("\n")).to include("12-2pm")
    expect(lines.join("\n")).not_to include("plunge")
    expect(described_class.plunge_offered?(lines)).to be(false)
  end

  # An all-day row runs local midnight to midnight, so it overlaps EVERY window
  # on its date. The travel chain and the collision check both exclude them.
  it "does not let an all-day row book the whole day out" do
    agenda = Agenda.create!(user: user, name: "Mine")
    AgendaItem.create!(
      agenda: agenda, name: "Marcos' Birthday", kind: :event, all_day: true,
      start_at: tz.parse("2026-07-28 00:00"), end_at: tz.parse("2026-07-29 00:00")
    )

    expect(lines_for(rain_hours: [12, 13]).join("\n")).to include(described_class::PLUNGE_PREFIX)
  end

  it "offers no plunge with nothing to read" do
    expect(described_class.plunge_offered?(nil)).to be(false)
  end

  # The week ahead, which is a different question from today's plunge window and
  # answered at two different resolutions: real hours for as far as the hourly
  # forecast reaches, and odds alone past that.
  describe ".week_rain_lines" do
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
      described_class.week_rain_lines(user, now: now).join("\n")
    end

    # Every timed day says what the hours are hours OF, so a wet window can't
    # be read as a dry one.
    it "gives rain as hours while the hourly forecast reaches, naming the day", :aggregate_failures do
      expect(block(rain_at: { "2026-08-21" => [13] })).to eq("tomorrow, rain 1-2pm")
      expect(block(rain_at: { "2026-08-21" => [13, 14, 15] })).to include("tomorrow, rain 1-4pm")
      expect(block(hours: 72, rain_at: { "2026-08-22" => [10, 11] })).to include("Saturday, rain 10am-12pm")

      out = block(hours: 72, rain_at: { "2026-08-21" => [12], "2026-08-22" => [10, 11] })
      expect(out.lines.map(&:strip)).to all(match(/rain/i))
    end

    # Today already has a block of its own directly above this one in the seed.
    it "names the last day of the week as next week's, not today's" do
      expect(block(daily_rain: { "2026-08-27" => 90 })).to include("next Thursday, rain at 90%")
    end

    it "lays the days out by date for the forecast table, today's hours included" do
      allow(WeatherService).to receive(:data).and_return(
        week_payload(hours: 72, rain_at: { "2026-08-20" => [13, 14], "2026-08-22" => [10, 11] }, daily_rain: { "2026-08-25" => 80 }),
      )

      expect(described_class.forecast_cells(user, now: now)).to eq(
        Date.new(2026, 8, 20) => "1-3pm",
        Date.new(2026, 8, 22) => "10am-12pm",
        Date.new(2026, 8, 25) => "80%",
      )
    end

    it "says nothing about today, a dry week, or rain nobody would be out in", :aggregate_failures do
      expect(block(rain_at: { "2026-08-20" => [13, 14] })).to eq("")
      expect(block(rain_at: { "2026-08-21" => [2, 3, 4] })).to eq("")
      expect(block).to eq("")
    end

    # Past 48 hours the forecast has one `pop` per day and nothing about when.
    # An invented afternoon would be the one failure worse than saying less.
    it "gives odds and no time once the hours run out" do
      out = block(daily_rain: { "2026-08-24" => 60 })

      expect(out).to include("Monday, rain at 60%")
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

    it "reaches him and nobody else", :aggregate_failures do
      travel_to(tz.parse("2026-08-20 07:00")) do
        expect(Buddy::BriefingFacts.alpine_lines(User.me, Time.current)[:week]).to be_present
        expect(Buddy::BriefingFacts.alpine?(user)).to be(false)
      end
    end
  end
end
