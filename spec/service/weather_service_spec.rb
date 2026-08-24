require "rails_helper"

RSpec.describe WeatherService do
  describe ".format_summary" do
    it "renders a compact one-liner from an onecall payload" do
      payload = {
        "current" => { "temp" => 72.4, "feels_like" => 72.0, "weather" => [{ "description" => "clear sky" }] },
        "daily"   => [{ "temp" => { "max" => 88.6, "min" => 61.2 }, "pop" => 0.2 }],
      }
      expect(described_class.format_summary(payload))
        .to eq("currently 72°F, clear sky. today high 89°F / low 61°F. chance of rain 20%.")
    end

    it "adds feels-like only when it diverges, and drops rain at 0%" do
      payload = {
        "current" => { "temp" => 30.0, "feels_like" => 21.0, "weather" => [{ "description" => "snow" }] },
        "daily"   => [{ "temp" => { "max" => 34.0, "min" => 18.0 }, "pop" => 0.0 }],
      }
      out = described_class.format_summary(payload)
      expect(out).to include("feels like 21°F")
      expect(out).not_to include("chance of rain")
    end
  end

  describe ".summary" do
    it "returns nil outside production (never hits the API from dev/test)" do
      expect(described_class.summary).to be_nil
    end
  end

  # `summary` reports the temperature, the sky and the rain odds. Wind isn't in
  # any of those, so a day of hard gusts read "currently 71°F, clear" and the
  # gusts reached no chat surface at all.
  describe ".today_notable" do
    def notable(day)
      allow(described_class).to receive(:data).and_return({ "daily" => [day] })
      described_class.today_notable
    end

    it "picks up wind the summary has no room for" do
      expect(notable({ "weather" => [{ "main" => "Clear" }], "pop" => 0.0, "wind_gust" => 38 })).to eq("windy")
    end

    it "is nil on an ordinary day" do
      expect(notable({ "weather" => [{ "main" => "Clear" }], "pop" => 0.05, "wind_speed" => 6 })).to be_nil
    end

    it "reads today, not tomorrow" do
      allow(described_class).to receive(:data).and_return({
        "daily" => [
          { "weather" => [{ "main" => "Clear" }], "pop" => 0.0 },
          { "weather" => [{ "main" => "Snow" }],  "pop" => 0.9 },
        ],
      })

      expect(described_class.today_notable).to be_nil
    end

    it "is nil when there's no forecast to read" do
      allow(described_class).to receive(:data).and_return(nil)

      expect(described_class.today_notable).to be_nil
    end
  end

  describe ".today_figures" do
    def figures(day)
      allow(described_class).to receive(:data).and_return({ "daily" => [day] })
      described_class.today_figures
    end

    it "hands back the numbers rather than the prose" do
      day = { "temp" => { "max" => 92.6, "min" => 68.7 }, "pop" => 0.56, "weather" => [{ "main" => "Rain" }] }

      expect(figures(day)).to eq(high: 93, low: 69, rain: 56, notable: "rain")
    end

    it "carries no notable label on an ordinary day" do
      day = { "temp" => { "max" => 78.2, "min" => 55.4 }, "pop" => 0.05, "weather" => [{ "main" => "Clear" }] }

      expect(figures(day)).to eq(high: 78, low: 55, rain: 5, notable: nil)
    end

    it "is nil when there's no forecast to read" do
      allow(described_class).to receive(:data).and_return(nil)

      expect(described_class.today_figures).to be_nil
    end
  end

  describe ".format_week_outlook" do
    it "flags notable days, grouped and ordered by severity, skipping calm days" do
      base = 1_700_000_000  # fixed so day names are deterministic-ish; \w{3} matches any
      payload = {
        "timezone_offset" => 0,
        "daily" => [
          { "dt" => base,             "weather" => [{ "main" => "Clear" }],  "pop" => 0.0 },                    # today → skipped
          { "dt" => base + 1 * 86400, "weather" => [{ "main" => "Rain" }],   "pop" => 0.6 },                    # rain
          { "dt" => base + 2 * 86400, "weather" => [{ "main" => "Clear" }],  "pop" => 0.05, "wind_speed" => 5 }, # calm → skip
          { "dt" => base + 3 * 86400, "weather" => [{ "main" => "Snow" }],   "pop" => 0.8 },                    # snow
          { "dt" => base + 4 * 86400, "weather" => [{ "main" => "Clear" }],  "pop" => 0.1, "wind_gust" => 35 }, # windy
        ],
      }

      expect(described_class.format_week_outlook(payload)).to match(/\Asnow \w{3}, rain \w{3}, windy \w{3}\z/)
    end

    it "returns nil for an unremarkable week" do
      payload = {
        "timezone_offset" => 0,
        "daily" => [
          { "dt" => 1,     "weather" => [{ "main" => "Clear" }],  "pop" => 0.0 },
          { "dt" => 86400, "weather" => [{ "main" => "Clouds" }], "pop" => 0.1, "wind_speed" => 6 },
        ],
      }
      expect(described_class.format_week_outlook(payload)).to be_nil
    end
  end
end
