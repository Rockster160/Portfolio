require "rails_helper"

# Bold stops being emphasis when there is more of it than there are sentences.
# See Buddy::Emphasis for the five mornings that produced this, and for why the
# line is drawn where it is.
RSpec.describe Buddy::Emphasis do
  # The shapes below are built to the same span/sentence ratios the real
  # briefings had, rather than quoting them.
  def briefing(sentences)
    sentences.join(" ")
  end

  describe "a briefing where emphasis is still scarce" do
    it "leaves it exactly as it was" do
      body = briefing([
        "Morning!",
        "**Dentist** is at 2:10 PM in Draper, so leave by 1:48.",
        "High of 61°F today with a 40% chance of rain.",
        "The week stays wet from Sunday through Thursday.",
        "Tonight has **Embroidery night** at 6.",
        "Four chores are due and nothing else is on.",
        "That is the lot.",
        "Have a good one.",
      ])

      expect(described_class.thin(body)).to eq(body)
    end

    # Below the floor there is nothing to measure, whatever the ratio says.
    it "leaves a short one alone even where every sentence carries bold" do
      body = "**Dentist** at 2. **Embroidery** at 6."

      expect(described_class.thin(body)).to eq(body)
    end
  end

  # 15 spans over 12 sentences, 14 of them figures - the morning the trend
  # started. Taking the numbers back leaves the one name still standing out,
  # which is the briefing the rule was always asking for.
  describe "a briefing that bolds the figures" do
    let(:body) {
      briefing([
        "Morning!",
        "**Dentist** is at **2:10 PM**, so leave by **1:48 PM**.",
        "High of **61°F** today, low of **43°F**.",
        "Rain odds are **40%** this morning and **20%** after.",
        "The week runs **70%**, **80%**, **98%**, **60%** and **30%**.",
        "Four chores are due.",
        "Nothing else is on.",
        "The plunge is at **5 PM**.",
        "Groceries after that.",
        "Bins go out tonight.",
        "That is the lot.",
        "Have a good one.",
      ])
    }

    it "takes the emphasis off the numbers" do
      out = described_class.thin(body)

      expect(out).to include("is at 2:10 PM")
      expect(out).to include("High of 61°F")
      expect(out).to include("are 40% this morning")
    end

    it "leaves the name carrying it, which is what a glance is looking for" do
      expect(described_class.thin(body)).to include("**Dentist**")
    end

    it "keeps every word it had" do
      expect(described_class.thin(body).delete("*")).to eq(body.delete("*"))
    end
  end

  # 37 spans over 8 sentences: every title, every time, every place, both
  # temperatures and both rain percentages. Which four of them were the ones
  # that mattered is not answerable from here, and the briefings that came out
  # clean on the same mornings had no bold at all.
  describe "a briefing where even the names are over the line" do
    let(:body) {
      briefing(
        (1..6).map { |n|
          "**Item #{n}** is at **#{n}:30 PM** at **Place #{n}** with **Person #{n}**, **booked**."
        },
      )
    }

    it "takes all of it off" do
      expect(described_class.thin(body)).not_to include("**")
    end

    it "still keeps every word" do
      expect(described_class.thin(body)).to eq(body.delete("*"))
    end
  end

  # Three sentences, five spans, two of them temperatures.
  describe "a short briefing bolding every fact in it" do
    let(:body) {
      "High of **55°F**, low **39°F**. Rain **Sunday, Monday and Friday**. " \
        "**PC income tasks** have waited **6 weeks**."
    }

    it "takes the bold off the figures" do
      expect(described_class.thin(body)).to include("High of 55°F, low 39°F.")
    end

    it "leaves the names their bold" do
      expect(described_class.thin(body)).to include("**PC income tasks**", "**Sunday, Monday and Friday**")
    end
  end

  describe "a title with italics in it" do
    it "is one span, not the start of the next one" do
      body = "Friday at 7pm is **Derek Halloween Party *bring Whisper***, and Saturday is **Tipsy treating**."

      expect(described_class.spans(body)).to eq(["Derek Halloween Party *bring Whisper*", "Tipsy treating"])
    end
  end

  describe "what it refuses to touch" do
    it "leaves italics alone" do
      body = briefing(["Morning! *boing*"] + (1..9).map { |n| "**Thing #{n}** is on." })

      expect(described_class.thin(body)).to include("*boing*")
    end

    it "leaves an unclosed pair where it is" do
      body = "Morning! **Dentist at 2:10 and then\nthe rest of it never closes."

      expect(described_class.thin(body)).to eq(body)
    end

    it "has nothing to say about an ordinary reply" do
      body = "Yep, **Dishes** is logged. **Mow** is the other one due."

      expect(described_class.thin(body)).to eq(body)
    end
  end
end
