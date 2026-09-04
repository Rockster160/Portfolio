require "rails_helper"

# Rocco, 2026-09-04, on the daily audit's "Suki said the same sentence twice in
# one reply": "Fix. This also happened on 5401."
#
# Two roads to one symptom. Prod 5296 is a generation artefact — one model call,
# no tools, no retry, and the second paragraph is the first one reworded. Prod
# 5401 is structural — a note the person wrote sitting over the task's own
# account of doing it.
RSpec.describe Buddy::Restatement do
  # Verbatim from prod, both of them, because the whole question is whether the
  # bar sits between real repetition and two paragraphs that merely rhyme.
  let(:said) {
    "It's there to nudge you, not just to scroll back to! When one pops up, the idea is that " \
      "it's the thing to act on or dismiss, and if it's just there as a note for later it'll " \
      "sit in the list too!"
  }
  let(:said_again) {
    "When one pops up, it's usually the thing to act on or dismiss, and if it's just a note " \
      "for later it can sit in the reminders list too!"
  }

  describe ".collapse" do
    it "drops the second telling and keeps the first" do
      expect(described_class.collapse("#{said}\n\n#{said_again}")).to eq(said)
    end

    it "leaves a single paragraph alone" do
      expect(described_class.collapse(said)).to eq(said)
    end

    # The expensive direction. A paragraph somebody meant to send is worth far
    # more than a repetitive one is worth removing.
    it "keeps two paragraphs that are about the same subject but say different things" do
      body = "I moved Do Dishes to 9 AM.\n\nI left the 8 PM one where it was, since you use both."

      expect(described_class.collapse(body)).to eq(body)
    end

    it "keeps a follow-up that adds something" do
      body = "#{said}\n\nWant me to move the 3 PM one to the evening instead?"

      expect(described_class.collapse(body)).to eq(body)
    end

    # Two bullet blocks in one briefing look alike for formatting reasons.
    it "never touches lists, headings or tables" do
      body = "- Do Dishes at 3 PM\n- Do Dishes at 8 PM\n\n- Do Dishes at 3 PM\n- Do Dishes at 8 PM"

      expect(described_class.collapse(body)).to eq(body)
    end

    # Below six significant words a paragraph is a fragment, and fragments look
    # alike for reasons that have nothing to do with repetition.
    it "leaves short lines alone, however similar" do
      body = "Do Dishes at 3 PM.\n\nDo Dishes at 8 PM."

      expect(described_class.collapse(body)).to eq(body)
    end
  end

  describe ".restates?" do
    it "is true for the same thing worded twice" do
      expect(described_class.restates?(said, said_again)).to be(true)
    end

    it "is false when the second one carries something new" do
      expect(described_class.restates?(said, "#{said_again} They also clear themselves once you tick them.")).to be(false)
    end

    # Prod 5401. A label over an answer that has now said the same thing, which
    # is the one case with structure behind it rather than only words.
    it "reads a label as restated by the answer underneath it" do
      expect(
        described_class.restates?("Whisper nap sound.", "Playing the nap sound on Whisper", min_words: 2),
      ).to be(true)
    end

    # The same loosened bar must not eat a label that means something the
    # answer doesn't say.
    it "keeps a label the answer doesn't cover" do
      expect(
        described_class.restates?("Running **Garage**", "Closing the garage now", min_words: 2),
      ).to be(false)
    end
  end
end
