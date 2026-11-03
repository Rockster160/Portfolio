require "rails_helper"

# A briefing floating one of their stashed thoughts under a name they never
# gave it. See Buddy::StashClaim.
RSpec.describe Buddy::StashClaim do
  # What Moss actually had, cut down to the sections that matter.
  let(:facts) {
    {
      name:    "Chelsea",
      today:   [{ time: "6:00 AM", title: "Hike with Nathan" }],
      week:    [{ day: "Wednesday", time: "6:00 PM", title: "Games with the crew" }],
      weather: { high: 72, low: 48, week: "rain Tue & Wed" },
      stash:   [{ id: 29, idea: "Desk storage for Rocco", waiting: "6 weeks" }],
    }
  }

  def trim(body) = described_class.trim(body, facts)

  it "drops a float that renamed the thought" do
    body = "Morning! Also, that front room drinks thing for Rocco is still sitting there if you want to come back to it later!"

    expect(trim(body)).to eq("Morning!")
  end

  # Half of the name is enough (see NAMED_ENOUGH). Only a sentence about
  # nothing else on the day, touching the thought's own words, is a candidate;
  # a figure, a real item, or plain warmth is left alone.
  it "keeps a float that names it, and every sentence that isn't a float", :aggregate_failures do
    [
      "Also, that Desk storage for Rocco thing is still sitting there, if you want to keep nudging it along!",
      "The desk storage idea is still sitting there if you fancy it.",
      "Rocco's hike with Nathan is at 6am, and it's still sitting on the calendar.",
      "That Rocco thing has been sitting there about 6 weeks now.",
      "Hey hey, good morning! Hope it's a gentle one.",
      # `(6 weeks)` would put `week` in the name's vocabulary; the age isn't part of it.
      "It feels like a good week to keep plugging away gently.",
      # Never hand back less than a sentence.
      "That front room drinks thing for Rocco is still sitting there!",
    ].each { |body| expect(trim(body)).to eq(body), body }
  end

  # Asked before `dropped_briefing_facts` complains the AGE went missing, and
  # the whole reason that arm cannot nag: a briefing is allowed to skip the
  # float entirely.
  describe ".named?" do
    def named?(body) = described_class.named?(body, facts)

    it "is true only when the thought is named as they wrote it", :aggregate_failures do
      expect(named?("Also, that Desk storage for Rocco thing is still sitting there!")).to be(true)
      expect(named?("Morning! Hike with Nathan at 6am, high of 72.")).to be(false)
      expect(named?("that front room drinks thing for Rocco is still sitting there")).to be(false)
      expect(described_class.named?("Desk storage for Rocco", facts.except(:stash))).to be(false)
    end
  end

  it "does nothing when the seed carried no stash at all" do
    body = "Also, that front room drinks thing for Rocco is still sitting there!"

    expect(described_class.trim(body, facts.except(:stash))).to eq(body)
  end
end
