require "rails_helper"

# When one thing has to start after another finishes. Back-to-back is not a
# plan: something ending at 1:31 and the next thing starting at 1:31 works on a
# calendar and not in a house.
RSpec.describe Buddy::FollowUp do
  def after(h, m)
    described_class.after(Time.zone.local(2026, 9, 8, h, m))
  end

  it "gives a breath and then a time a person would say" do
    expect(after(13, 31)).to eq(Time.zone.local(2026, 9, 8, 13, 40))
  end

  it "never gives less than the leeway" do
    # 1:36 + 5 is 1:41, and :45 is the next slot — not :40, which is behind it.
    expect(after(13, 36)).to eq(Time.zone.local(2026, 9, 8, 13, 45))
  end

  it "takes a time already on a slot at exactly the leeway" do
    expect(after(13, 35)).to eq(Time.zone.local(2026, 9, 8, 13, 40))
  end

  it "rolls into the next hour past the last slot" do
    # 1:46 + 5 is 1:51, and there is no slot after :50.
    expect(after(13, 46)).to eq(Time.zone.local(2026, 9, 8, 14, 0))
  end

  it "keeps going forward once it has rolled over" do
    expect(after(13, 56)).to eq(Time.zone.local(2026, 9, 8, 14, 10))
  end

  # :35 and :55 are arithmetic. Nobody proposes them out loud.
  it "never lands on a five that isn't a ten or a quarter" do
    minutes = (0..59).map { |m| after(13, m).min }
    expect(minutes.uniq.sort).to all(be_in(described_class::SLOTS))
  end

  it "always moves forward, never back" do
    (0..59).each { |m|
      base = Time.zone.local(2026, 9, 8, 13, m)
      expect(described_class.after(base)).to be > base
    }
  end

  it "swallows the seconds a computed epoch carries" do
    at = Time.zone.local(2026, 9, 8, 13, 31, 42)

    expect(described_class.after(at)).to eq(Time.zone.local(2026, 9, 8, 13, 40))
  end

  it "has no answer for nothing" do
    expect(described_class.after(nil)).to be_nil
  end
end
