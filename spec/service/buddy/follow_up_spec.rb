require "rails_helper"

# When one thing has to start after another finishes: a breath of leeway, then
# the next time a person would say out loud.
RSpec.describe Buddy::FollowUp do
  def at(h, m, s=0)
    Time.zone.local(2026, 9, 8, h, m, s)
  end

  it "rounds up past the leeway onto the next ten or quarter", :aggregate_failures do
    [
      [at(13, 31), at(13, 40)],
      # 1:36 + 5 is 1:41, and :45 is the next slot, not :40 behind it.
      [at(13, 36), at(13, 45)],
      [at(13, 35), at(13, 40)],
      # No slot after :50, so it rolls into the next hour and keeps going.
      [at(13, 46), at(14, 0)],
      [at(13, 56), at(14, 10)],
      # The seconds a computed epoch carries are swallowed.
      [at(13, 31, 42), at(13, 40)],
    ].each do |from, expected|
      expect(described_class.after(from)).to eq(expected), from.to_s
    end
  end

  it "always moves forward onto a slot, for every minute of the hour", :aggregate_failures do
    (0..59).each { |m|
      landed = described_class.after(at(13, m))
      expect(landed).to be > at(13, m)
      expect(described_class::SLOTS).to include(landed.min)
    }
  end

  it "has no answer for nothing" do
    expect(described_class.after(nil)).to be_nil
  end
end
