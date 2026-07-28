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
