require "rails_helper"

RSpec.describe GoogleCalendar::RRule do
  describe ".translate" do
    it "returns nil for input without an RRULE line" do
      expect(described_class.translate([])).to be_nil
      expect(described_class.translate(["EXDATE:20260114T090000Z"])).to be_nil
    end

    it "maps DAILY interval=1 onto :daily" do
      result = described_class.translate(["RRULE:FREQ=DAILY"])
      expect(result[:recurrence]).to eq(freq: :daily)
      expect(result[:until_on]).to be_nil
      expect(result[:occurrence_count]).to be_nil
    end

    it "maps DAILY interval>1 onto custom-day" do
      result = described_class.translate(["RRULE:FREQ=DAILY;INTERVAL=3"])
      expect(result[:recurrence]).to eq(freq: :custom, unit: :day, interval: 3)
    end

    it "maps Mon-Fri WEEKLY onto :weekdays" do
      result = described_class.translate(["RRULE:FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"])
      expect(result[:recurrence]).to eq(freq: :weekdays)
    end

    it "maps an arbitrary WEEKLY onto :weekly with by_day" do
      result = described_class.translate(["RRULE:FREQ=WEEKLY;BYDAY=MO,WE"])
      expect(result[:recurrence][:freq]).to eq(:weekly)
      expect(result[:recurrence][:by_day]).to match_array(%w[mon wed])
    end

    it "maps biweekly onto custom-week" do
      result = described_class.translate(["RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TH"])
      expect(result[:recurrence][:freq]).to eq(:custom)
      expect(result[:recurrence][:unit]).to eq(:week)
      expect(result[:recurrence][:interval]).to eq(2)
      expect(result[:recurrence][:by_day]).to eq(%w[thu])
    end

    it "maps MONTHLY BYMONTHDAY onto :monthly with by_month_day" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;BYMONTHDAY=1,15"])
      expect(result[:recurrence]).to include(freq: :monthly, by_month_day: [1, 15])
    end

    it "maps MONTHLY BYSETPOS+BYDAY onto monthly Nth weekday" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;BYSETPOS=2;BYDAY=TU"])
      expect(result[:recurrence]).to include(
        freq:       :monthly,
        by_set_pos: 2,
        by_day:     ["tue"],
      )
    end

    it "maps MONTHLY inline-positioned BYDAY (BYDAY=3TU) onto monthly Nth weekday" do
      # Google's actual emission for "monthly on the third Tuesday" — pos is
      # prefixed inside BYDAY rather than via a separate BYSETPOS.
      result = described_class.translate(["RRULE:FREQ=MONTHLY;BYDAY=3TU"])
      expect(result[:recurrence]).to eq(
        freq:       :monthly,
        by_set_pos: 3,
        by_day:     ["tue"],
      )
    end

    it "maps MONTHLY BYDAY=-1FR (last Friday) with no separate BYSETPOS" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;BYDAY=-1FR"])
      expect(result[:recurrence]).to eq(
        freq:       :monthly,
        by_set_pos: -1,
        by_day:     ["fri"],
      )
    end

    it "maps MONTHLY INTERVAL=3 (no BYDAY/BYMONTHDAY) onto custom-month with interval" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;INTERVAL=3"])
      expect(result[:recurrence]).to eq(
        freq:     :custom,
        unit:     :month,
        interval: 3,
      )
    end

    it "maps FREQ=MONTHLY;INTERVAL=3;BYDAY=3TU (All Hands rule) onto custom-month nth-weekday" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;INTERVAL=3;BYDAY=3TU"])
      expect(result[:recurrence]).to eq(
        freq:       :custom,
        unit:       :month,
        interval:   3,
        by_set_pos: 3,
        by_day:     ["tue"],
      )
      expect(result[:partial]).to be(false)
    end

    it "maps MONTHLY INTERVAL>1 + BYMONTHDAY onto custom-month with by_month_day" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;INTERVAL=2;BYMONTHDAY=15"])
      expect(result[:recurrence]).to eq(
        freq:         :custom,
        unit:         :month,
        interval:     2,
        by_month_day: [15],
      )
    end

    it "flags multiple positioned BYDAY entries as partial (collapses to first)" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;BYDAY=1MO,3MO"])
      expect(result[:recurrence]).to include(by_set_pos: 1, by_day: ["mon"])
      expect(result[:partial]).to be(true)
    end

    it "flags inline-BYDAY vs separate BYSETPOS disagreement as partial" do
      result = described_class.translate(["RRULE:FREQ=MONTHLY;BYDAY=3TU;BYSETPOS=2"])
      # Inline prefix wins, but caller sees partial:true.
      expect(result[:recurrence]).to include(by_set_pos: 3, by_day: ["tue"])
      expect(result[:partial]).to be(true)
    end

    it "captures UNTIL onto until_on" do
      result = described_class.translate(["RRULE:FREQ=DAILY;UNTIL=20271231T235959Z"])
      expect(result[:until_on]).to eq(Date.new(2027, 12, 31))
    end

    it "captures COUNT onto occurrence_count" do
      result = described_class.translate(["RRULE:FREQ=DAILY;COUNT=10"])
      expect(result[:occurrence_count]).to eq(10)
    end

    it "merges EXDATE entries into recurrence[:excluded_dates]" do
      result = described_class.translate([
        "RRULE:FREQ=DAILY",
        "EXDATE;TZID=America/New_York:20260714T090000",
        "EXDATE:20260715T090000Z",
      ])
      expect(result[:recurrence][:excluded_dates]).to contain_exactly("2026-07-14", "2026-07-15")
    end

    it "returns skip:true for sub-day FREQ tokens (HOURLY/MINUTELY/SECONDLY)" do
      %w[HOURLY MINUTELY SECONDLY].each do |freq|
        result = described_class.translate(["RRULE:FREQ=#{freq};INTERVAL=5"])
        expect(result[:skip]).to be(true), "expected skip:true for #{freq}"
      end
    end

    it "flags multiple RRULEs on one event as partial" do
      result = described_class.translate([
        "RRULE:FREQ=WEEKLY;BYDAY=MO",
        "RRULE:FREQ=WEEKLY;BYDAY=FR",
      ])
      expect(result[:partial]).to be(true)
      expect(result[:recurrence][:by_day]).to eq(["mon"]) # first wins
    end

    it "flags multi-month BYMONTH as partial" do
      result = described_class.translate(["RRULE:FREQ=YEARLY;BYMONTH=3,6,9;BYMONTHDAY=1"])
      expect(result[:partial]).to be(true)
    end

    it "stores RDATE inclusions in recurrence[:included_dates]" do
      result = described_class.translate([
        "RRULE:FREQ=DAILY",
        "RDATE;TZID=America/New_York:20260714T090000",
      ])
      expect(result[:recurrence][:included_dates]).to eq(["2026-07-14"])
    end

    it "flags BYYEARDAY/BYWEEKNO/BYHOUR refinements as partial" do
      result = described_class.translate(["RRULE:FREQ=YEARLY;BYYEARDAY=100"])
      expect(result[:partial]).to be(true)
    end
  end
end
