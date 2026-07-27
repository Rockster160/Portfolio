require "rails_helper"

RSpec.describe Buddy::TimeParser do
  include ActiveSupport::Testing::TimeHelpers

  let(:user) { instance_double(User, timezone: "America/Denver") }

  around { |ex|
    travel_to(Time.zone.parse("2026-07-27T15:00:00-06:00")) { ex.run }
  }

  describe ".parse_past" do
    it "returns nil for blank and 'now'" do
      expect(described_class.parse_past(nil, user: user)).to be_nil
      expect(described_class.parse_past("", user: user)).to be_nil
      expect(described_class.parse_past("now", user: user)).to be_nil
    end

    it "parses ISO timestamps" do
      t = described_class.parse_past("2026-07-27T10:00:00-06:00", user: user)
      expect(t).to eq(Time.zone.parse("2026-07-27T10:00:00-06:00"))
    end

    it "parses 'an hour ago' as -1 hour" do
      expect(described_class.parse_past("an hour ago", user: user)).to eq(Time.current - 1.hour)
    end

    it "parses '30 minutes ago'" do
      expect(described_class.parse_past("30 minutes ago", user: user)).to eq(Time.current - 30.minutes)
    end

    it "parses '2 hours ago'" do
      expect(described_class.parse_past("2 hours ago", user: user)).to eq(Time.current - 2.hours)
    end

    it "parses 'this morning' as 8am today" do
      t = described_class.parse_past("this morning", user: user)
      expect(t.hour).to eq(8)
      expect(t.to_date).to eq(Time.current.in_time_zone("America/Denver").to_date)
    end

    it "parses '8:15am' as today 8:15" do
      t = described_class.parse_past("8:15am", user: user)
      expect(t.hour).to eq(8)
      expect(t.min).to eq(15)
    end

    it "parses '7pm' as today 19:00" do
      t = described_class.parse_past("7pm", user: user)
      expect(t.hour).to eq(19)
    end

    it "rolls a future clock time back a day" do
      # It's 3pm — user says "8pm" — that's still upcoming today, so
      # interpret as yesterday 8pm.
      t = described_class.parse_past("8pm", user: user)
      expect(t.to_date).to eq(Time.current.in_time_zone("America/Denver").to_date - 1)
    end
  end

  describe ".friendly" do
    it "renders today times without a date prefix" do
      s = described_class.friendly("2026-07-27T14:15:00-06:00", user: user)
      expect(s).to match(/2:15\s?pm/i)
    end

    it "prefixes 'yesterday' for prior-day times" do
      s = described_class.friendly("2026-07-26T14:15:00-06:00", user: user)
      expect(s).to start_with("yesterday")
    end
  end
end
