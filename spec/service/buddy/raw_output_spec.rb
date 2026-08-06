require "rails_helper"

# Prod 2636: a sensor reading came back "last changed:
# 2026-08-05T18:58:03.888986+00:00" and the seed asked the model to convert it.
# It answered "since about 6:58 PM" — the same digits with the offset thrown
# away, six hours out, and said with total confidence.
RSpec.describe Buddy::RawOutput do
  let(:user) { create(:user) }
  let(:zone) { ActiveSupport::TimeZone[user.timezone] }

  def at(local_time, &block)
    travel_to(zone.parse(local_time), &block)
  end

  describe ".localize" do
    it "converts a UTC stamp to their clock rather than restating the digits" do
      at("2026-08-05 14:00:00") {
        out = described_class.localize("kennel is closed (last changed: 2026-08-05T18:58:03.888986+00:00)", user)

        expect(out).to include("12:58 PM today")
        expect(out).not_to include("6:58 PM")
        expect(out).not_to include("18:58")
      }
    end

    it "says which day when it wasn't today" do
      at("2026-08-05 14:00:00") {
        expect(described_class.localize("2026-08-04T18:58:03+00:00", user)).to eq("12:58 PM yesterday")
        expect(described_class.localize("2026-07-30T02:14:14+00:00", user)).to eq("8:14 PM on Jul 29")
      }
    end

    it "handles a Z suffix and an offset that isn't zero" do
      at("2026-08-05 14:00:00") {
        expect(described_class.localize("2026-08-05T18:58:03Z", user)).to eq("12:58 PM today")
        expect(described_class.localize("2026-08-05T14:58:03-04:00", user)).to eq("12:58 PM today")
      }
    end

    it "leaves the rest of the line exactly as it was" do
      at("2026-08-05 14:00:00") {
        out = described_class.localize("laundry_gate is open (raw state: on, last changed: 2026-08-05T18:58:03Z)", user)

        expect(out).to start_with("laundry_gate is open (raw state: on, last changed: ")
        expect(out).to end_with(")")
      }
    end

    # Guessing a zone for a bare stamp is the bug, not the fix.
    it "leaves a stamp with no zone on it alone" do
      expect(described_class.localize("last changed: 2026-08-05 18:58:03", user))
        .to eq("last changed: 2026-08-05 18:58:03")
    end

    it "passes through text with no timestamps at all" do
      expect(described_class.localize("kennel is closed", user)).to eq("kennel is closed")
    end

    it "rewrites every stamp in a line, not just the first" do
      at("2026-08-05 14:00:00") {
        out = described_class.localize("opened 2026-08-05T18:00:00Z, closed 2026-08-05T18:58:03Z", user)

        expect(out).to eq("opened 12:00 PM today, closed 12:58 PM today")
      }
    end
  end
end
