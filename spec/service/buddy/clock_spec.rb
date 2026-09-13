require "rails_helper"

RSpec.describe Buddy::Clock do
  let(:zone) { "America/Denver" }
  let(:tz)   { ActiveSupport::TimeZone[zone] }

  describe ".at" do
    it "drops the minutes on the hour" do
      expect(described_class.at(tz.parse("2026-09-13 15:00"))).to eq("3pm")
    end

    it "keeps them when there are any" do
      expect(described_class.at(tz.parse("2026-09-13 15:15"))).to eq("3:15pm")
    end

    it "pads the minutes rather than the hour" do
      expect(described_class.at(tz.parse("2026-09-13 09:05"))).to eq("9:05am")
    end

    it "reads a string as well as a time" do
      expect(described_class.at("2026-09-13T15:00:00-06:00", zone: zone)).to eq("3pm")
    end

    it "moves into the zone it is given" do
      expect(described_class.at(Time.utc(2026, 9, 13, 21, 0), zone: zone)).to eq("3pm")
    end

    it "has nothing to say about nothing" do
      expect(described_class.at(nil)).to be_nil
      expect(described_class.at("not a time")).to be_nil
    end
  end

  # Rocco, 2026-09-13: "the whole '3:00 PM to 4:00 PM' is really excessive and
  # redundant and gets hard to read quickly."
  describe ".range" do
    def range(from, to)
      described_class.range(tz.parse("2026-09-13 #{from}"), tz.parse("2026-09-13 #{to}"))
    end

    it "says the meridiem once when both ends share it" do
      expect(range("15:00", "16:00")).to eq("3-4pm")
    end

    it "keeps the minutes that are there" do
      expect(range("15:30", "16:15")).to eq("3:30-4:15pm")
    end

    it "says both when the range crosses noon" do
      expect(range("11:00", "13:00")).to eq("11am-1pm")
    end

    it "says both when it crosses midnight" do
      a = tz.parse("2026-09-13 23:00")
      b = tz.parse("2026-09-14 01:00")

      expect(described_class.range(a, b)).to eq("11pm-1am")
    end

    # The one range where the shorthand would lie: 3pm one day to 3pm the next
    # is not "3-3pm".
    it "spells both out across a day boundary that shares a meridiem" do
      a = tz.parse("2026-09-13 15:00")
      b = tz.parse("2026-09-14 15:00")

      expect(described_class.range(a, b)).to eq("3pm-3pm")
    end

    it "collapses to one time when both ends are the same" do
      expect(range("15:00", "15:00")).to eq("3pm")
    end

    it "falls back to whichever end it has" do
      start = tz.parse("2026-09-13 15:00")

      expect(described_class.range(start, nil)).to eq("3pm")
      expect(described_class.range(nil, start)).to eq("3pm")
    end
  end

  describe ".day_at and .date_at" do
    let(:at) { tz.parse("2026-09-13 15:00") }

    it "puts the weekday in front" do
      expect(described_class.day_at(at)).to eq("Sun 3pm")
    end

    it "puts the whole date in front" do
      expect(described_class.date_at(at)).to eq("Sun Sep 13, 3pm")
    end
  end
end
