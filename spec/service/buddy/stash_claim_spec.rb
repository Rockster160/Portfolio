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

  # The sentence, verbatim. There is no front room and there are no drinks.
  it "drops a float that renamed the thought" do
    body = "Morning! Also, that front room drinks thing for Rocco is still sitting there if you want to come back to it later!"

    expect(trim(body)).to eq("Morning!")
  end

  # The same shape, said right, on the morning after. This is the sentence the
  # guard exists to leave alone.
  it "keeps a float that names it as they wrote it" do
    body = "Also, that Desk storage for Rocco thing is still sitting there, if you want to keep nudging it along!"

    expect(trim(body)).to eq(body)
  end

  # Half of what makes the line its own is enough - a float abbreviates the
  # same way an ATS headline does, and demanding the whole phrase would cut
  # the ordinary case. See NAMED_ENOUGH.
  it "keeps a float that names most of it" do
    body = "The desk storage idea is still sitting there if you fancy it."

    expect(trim(body)).to eq(body)
  end

  # The guard only ever looks at sentences that are about nothing else on the
  # day. A sentence carrying a real item is news, whatever it also mentions.
  it "leaves a sentence about something real on the day alone" do
    body = "Rocco's hike with Nathan is at 6am, and it's still sitting on the calendar."

    expect(trim(body)).to eq(body)
  end

  it "leaves a figure alone" do
    body = "That Rocco thing has been sitting there about 6 weeks now."

    expect(trim(body)).to eq(body)
  end

  # Warmth names nothing, reaches for nothing, and must survive. Only a
  # sentence that touches the thought's own words is ever a candidate.
  it "leaves the greeting and the sign-off alone" do
    body = "Hey hey, good morning! Hope it's a gentle one."

    expect(trim(body)).to eq(body)
  end

  it "does nothing when the seed carried no stash at all" do
    body = "Also, that front room drinks thing for Rocco is still sitting there!"

    expect(described_class.trim(body, facts.except(:stash))).to eq(body)
  end

  # Never hand back less than a sentence, same as the repairs either side.
  it "keeps a body that was nothing but the float" do
    body = "That front room drinks thing for Rocco is still sitting there!"

    expect(trim(body)).to eq(body)
  end

  # `(6 weeks)` puts `week` into the line's vocabulary, and `week` is a word
  # every briefing ever written contains. The thought is read without its age.
  it "does not treat the age bracket as part of the name" do
    body = "It feels like a good week to keep plugging away gently."

    expect(trim(body)).to eq(body)
  end
end
