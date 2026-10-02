require "rails_helper"

# The briefing saying something its seed never carried.
#
# Prod 6137, 15 Sep: a weather-only seed, and a briefing that moved Eve's pantry
# day to Tuesday by reading her own sentence from the night before forward
# unchanged. See Buddy::DayClaim.
RSpec.describe Buddy::DayClaim do
  # What Suki actually had, in the shape the seed actually carries it - seed
  # 6135's `weather` is a hash with a `week` outlook in it, and the day check
  # reads that field rather than the facts' text.
  let(:facts) {
    { weather: { low: 53, high: 74, week: "rain Wed, Thu & Fri" } }
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

  # Prod 7239/7240, 1 Oct. Byte opened Thursday's briefing "Busy one tomorrow,
  # but a good one" over a day holding a 10am iCapital interview. Read on a lock
  # screen that moves the interview to Friday.
  #
  # The word was in the facts - as the title of an 8pm chore, "Set alarm for
  # tomorrow!" - so the overlap test had its evidence handed to it by the one
  # thing on the day that was not about tomorrow at all.
  describe "a day word that is part of a NAME" do
    let(:facts) {
      {
        today:   [
          { time: "10am", title: "Interview: iCapital" },
          { time: "8pm", title: "Set alarm for tomorrow!" },
        ],
        week:    [
          { day: "Saturday", time: "8am", title: "Fun Run!" },
          { day: "Tuesday", time: "5:30pm", title: "IT Performance" },
        ],
        weather: { low: 52, high: 76 },
      }
    }

    it "drops a claim about tomorrow when nothing is scheduled for tomorrow" do
      body = "Hey hey, Rocco! Busy one tomorrow, but a good one."

      expect(trim(body)).to eq("Hey hey, Rocco!")
    end

    # The other half: the week IS what says which days are covered, so a day it
    # names is reporting rather than inventing.
    it "keeps a claim about a day the week has something on" do
      body = "Morning! Saturday is the one to watch."

      expect(trim(body)).to eq(body)
    end

    it "keeps tomorrow once the week actually has something on it" do
      facts[:week] << { day: "tomorrow", time: "6:30pm", title: "Crochet with Eve" }
      body = "Morning! Tomorrow has its own thing going on."

      expect(trim(body)).to eq(body)
    end
  end

  # Prod 6381, 16 Sep. The seed's outlook read "rain Thu, Fri & Sat" and the
  # briefing wrote the days out in full, which is what it is asked to do - so
  # the sentence shares no WORD with the facts ("rainy" is not "rain",
  # "Thursday" is not "Thu") and anything comparing word sets cuts a correct
  # forecast. The days are read off the outlook, abbreviations expanded, for
  # exactly this.
  it "keeps the week's own rain, spelled out" do
    facts[:weather][:week] = "rain Thu, Fri & Sat"
    body = "Morning! This week looks rainy on Thursday, Friday, and Saturday too!"

    expect(trim(body)).to eq(body)
  end

  # No schedule in the facts at all is not "no day is covered" - it is nothing
  # to judge days by, so the overlap test is left to it and a sentence it clears
  # survives. An empty set in place of that would have cut this one, because
  # nothing can be said to cover tomorrow.
  it "falls back to the overlap when the facts carry no week at all" do
    bare = { weather: { low: 52, high: 76, notable: "rain" } }
    body = "Morning! Rain is coming tomorrow."

    expect(described_class.trim(body, bare)).to eq(body)
  end
end
