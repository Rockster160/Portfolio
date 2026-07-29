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

  it "does NOT call it a good plunge day when the agenda conflicts" do
    agenda = Agenda.create!(user: user, name: "Mine")
    AgendaItem.create!(
      agenda: agenda, name: "Meeting", kind: :event,
      start_at: tz.parse("2026-07-28 12:00"), end_at: tz.parse("2026-07-28 13:00")
    )
    allow(WeatherService).to receive(:data).and_return(payload(day: "2026-07-28", rain_hours: [12, 13]))

    block = described_class.briefing_block(user, now: tz.parse("2026-07-28 07:00"))
    expect(block).to include("Not really a plunge day")
  end

  it "flags heavy dark clouds even without rain" do
    clouds = { 10 => 90, 11 => 88, 12 => 85 }
    allow(WeatherService).to receive(:data).and_return(payload(day: "2026-07-28", cloud_hours: clouds))
    block = described_class.briefing_block(user, now: tz.parse("2026-07-28 07:00"))
    expect(block).to include("dark cloud")
  end
end
