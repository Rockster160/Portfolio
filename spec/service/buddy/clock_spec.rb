require "rails_helper"

RSpec.describe Buddy::Clock do
  let(:zone) { "America/Denver" }
  let(:tz)   { ActiveSupport::TimeZone[zone] }

  describe ".at" do
    it "drops :00, pads minutes not hours, reads strings and moves into the zone", :aggregate_failures do
      expect(described_class.at(tz.parse("2026-09-13 15:00"))).to eq("3pm")
      expect(described_class.at(tz.parse("2026-09-13 15:15"))).to eq("3:15pm")
      expect(described_class.at(tz.parse("2026-09-13 09:05"))).to eq("9:05am")
      expect(described_class.at("2026-09-13T15:00:00-06:00", zone: zone)).to eq("3pm")
      expect(described_class.at(Time.utc(2026, 9, 13, 21, 0), zone: zone)).to eq("3pm")
    end

    it "has nothing to say about nothing" do
      expect(described_class.at(nil)).to be_nil
      expect(described_class.at("not a time")).to be_nil
    end
  end

  describe ".range" do
    it "shares the meridiem only when both ends sit on the same side of noon on the same day" do
      [
        ["2026-09-13 15:00", "2026-09-13 16:00", "3-4pm"],
        ["2026-09-13 15:30", "2026-09-13 16:15", "3:30-4:15pm"],
        ["2026-09-13 11:00", "2026-09-13 13:00", "11am-1pm"],
        ["2026-09-13 23:00", "2026-09-14 01:00", "11pm-1am"],
        # 3pm one day to 3pm the next is not "3-3pm".
        ["2026-09-13 15:00", "2026-09-14 15:00", "3pm-3pm"],
        ["2026-09-13 15:00", "2026-09-13 15:00", "3pm"],
      ].each { |from, to, expected|
        expect(described_class.range(tz.parse(from), tz.parse(to))).to eq(expected), "#{from} → #{to}"
      }
    end

    it "falls back to whichever end it has" do
      start = tz.parse("2026-09-13 15:00")

      expect(described_class.range(start, nil)).to eq("3pm")
      expect(described_class.range(nil, start)).to eq("3pm")
    end
  end

  it "puts the weekday or the whole date in front" do
    at = tz.parse("2026-09-13 15:00")

    expect(described_class.day_at(at)).to eq("Sun 3pm")
    expect(described_class.date_at(at)).to eq("Sun Sep 13, 3pm")
  end
end
