require "rails_helper"

# One reply saying the same thing twice: a paragraph reworded by the model, or
# a label sitting over the task's own account of doing it.
RSpec.describe Buddy::Restatement do
  # The question is whether the bar sits between real repetition and two
  # paragraphs that merely rhyme.
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

    # A paragraph somebody meant to send is worth far more than a repetitive one
    # is worth removing. Lists look alike for formatting reasons, and below six
    # significant words a paragraph is a fragment.
    it "leaves single paragraphs, different points, follow-ups, lists and short lines alone", :aggregate_failures do
      [
        said,
        "I moved Do Dishes to 9 AM.\n\nI left the 8 PM one where it was, since you use both.",
        "#{said}\n\nWant me to move the 3 PM one to the evening instead?",
        "- Do Dishes at 3 PM\n- Do Dishes at 8 PM\n\n- Do Dishes at 3 PM\n- Do Dishes at 8 PM",
        "Do Dishes at 3 PM.\n\nDo Dishes at 8 PM.",
      ].each { |body| expect(described_class.collapse(body)).to eq(body) }
    end
  end

  describe ".restates?" do
    it "is true for the same thing worded twice, false once it carries something new", :aggregate_failures do
      expect(described_class.restates?(said, said_again)).to be(true)
      expect(described_class.restates?(said, "#{said_again} They also clear themselves once you tick them.")).to be(false)
    end

    # A label over an answer, with a loosened bar that must still keep a label
    # meaning something the answer doesn't say.
    it "reads a label as restated only by an answer that covers it", :aggregate_failures do
      expect(
        described_class.restates?("Whisper nap sound.", "Playing the nap sound on Whisper", min_words: 2),
      ).to be(true)
      expect(
        described_class.restates?("Running **Garage**", "Closing the garage now", min_words: 2),
      ).to be(false)
    end
  end
end
