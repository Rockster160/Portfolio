require "rails_helper"

# Tool output carrying ISO stamps is rewritten onto the person's own clock
# before the model sees it, rather than asking the model to convert them.
RSpec.describe Buddy::RawOutput do
  let(:user) { create(:user) }
  let(:zone) { ActiveSupport::TimeZone[user.timezone] }

  describe ".localize" do
    it "rewrites every zoned stamp onto their clock, naming the day, and leaves the rest of the line", :aggregate_failures do
      travel_to(zone.parse("2026-08-05 14:00:00")) {
        [
          ["kennel is closed (last changed: 2026-08-05T18:58:03.888986+00:00)", "kennel is closed (last changed: 12:58pm today)"],
          ["2026-08-04T18:58:03+00:00", "12:58pm yesterday"],
          ["2026-07-30T02:14:14+00:00", "8:14pm on Jul 29"],
          ["2026-08-05T18:58:03Z", "12:58pm today"],
          ["2026-08-05T14:58:03-04:00", "12:58pm today"],
          ["laundry_gate is open (raw state: on, last changed: 2026-08-05T18:58:03Z)", "laundry_gate is open (raw state: on, last changed: 12:58pm today)"],
          ["opened 2026-08-05T18:00:00Z, closed 2026-08-05T18:58:03Z", "opened 12pm today, closed 12:58pm today"],
        ].each do |raw, expected|
          expect(described_class.localize(raw, user)).to eq(expected), raw
        end
      }
    end

    # Guessing a zone for a bare stamp is the bug, not the fix.
    it "leaves a stamp with no zone, or text with no stamp, alone", :aggregate_failures do
      expect(described_class.localize("last changed: 2026-08-05 18:58:03", user)).to eq("last changed: 2026-08-05 18:58:03")
      expect(described_class.localize("kennel is closed", user)).to eq("kennel is closed")
    end

    # A function reporting that it worked is not saying a word; a reading that
    # arrives as a number is still an answer.
    it "has nothing to say about a flag, but says a number", :aggregate_failures do
      expect(described_class.localize(true, user)).to be_nil
      expect(described_class.localize(false, user)).to be_nil
      expect(described_class.localize(72, user)).to eq("72")
    end
  end
end
