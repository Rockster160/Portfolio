require "rails_helper"

# The briefing saying something its seed never carried.
#
# Prod 6137, 15 Sep: a weather-only seed, and a briefing that moved Eve's pantry
# day to Tuesday by reading her own sentence from the night before forward
# unchanged. See Buddy::DayClaim.
RSpec.describe Buddy::DayClaim do
  # What Suki actually had, verbatim.
  let(:facts) {
    { weather: ["High 74°F, low 53°F", "This week: rain Wed, Thu & Fri"] }
  }

  def trim(body) = described_class.trim(body, facts)

  it "drops the claim about a day the facts never mentioned" do
    body = "Morning! Tomorrow still looks like a pantry-start kind of day, so today can stay focused and steady."

    expect(trim(body)).to eq("Morning!")
  end

  # The half that must survive. A briefing IS about today, and "today looks
  # quiet" is the job it was given - cutting that would leave the morning with
  # nothing in it.
  it "leaves today alone, even with nothing behind it" do
    body = "Today looks pretty open, so there's room to breathe."

    expect(trim(body)).to eq(body)
  end

  # The seed DOES carry the week, so a sentence about it is reporting rather
  # than inventing. This is the whole reason the test is word overlap and not a
  # ban on future tense.
  it "keeps a future day the facts do cover" do
    body = "Rain's coming Wed through Fri, so the dry stretch is now."

    expect(trim(body)).to eq(body)
  end

  it "keeps a sentence carrying a figure, whatever the overlap says" do
    body = "Saturday should reach about 80, so it'll be a warm one."

    expect(trim(body)).to eq(body)
  end

  it "takes a weekday claim with nothing behind it" do
    body = "It's a good morning for it. Thursday feels like the day for that catch-up."

    expect(trim(body)).to eq("It's a good morning for it.")
  end

  it "takes a weekend claim with nothing behind it" do
    body = "Sleep in a bit. The weekend still looks like the one for sorting the garage."

    expect(trim(body)).to eq("Sleep in a bit.")
  end

  # Never hand back less than a sentence, same rule Flourish keeps: a body that
  # was nothing BUT the claim is a generation this has no opinion about, and
  # punctuation on its own is not a briefing.
  it "leaves a body that was nothing but the claim alone" do
    body = "Tomorrow looks like a pantry kind of day."

    expect(trim(body)).to eq(body)
  end

  it "keeps the paragraph break around what it drops" do
    body = "High of 74 today.\n\nTomorrow's a pantry-start kind of day.\n\nRain lands Wed."

    expect(trim(body)).to eq("High of 74 today.\n\nRain lands Wed.")
  end

  it "says nothing about a body with no day in it at all" do
    body = "Hope the kitchen behaves itself."

    expect(trim(body)).to eq(body)
  end

  it "hands the body back untouched when the facts are empty" do
    expect(described_class.trim("Morning!", {})).to eq("Morning!")
  end
end
