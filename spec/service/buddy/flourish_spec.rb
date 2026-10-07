require "rails_helper"

# Rocco, 2026-09-05: "'{statement} which is {unnecessary description}' is back
# and annoying."
#
# The fourth attempt at this and the first that isn't prose. TONE banned the
# shape and it moved mid-sentence; the ban became the FUNCTION plus a
# subtraction test, and the original shape came back anyway. What's mechanised
# here is the subtraction test itself, for the one shape where "says as much"
# can actually be computed.
RSpec.describe Buddy::Flourish do
  # The day it was attached to, as words. Only the words matter.
  let(:facts) {
    { today: [{ time: "6:00 PM", title: "meatballs & power Mac" }], weather: { week: "rain Sun & Mon" } }
  }

  def trim(body, day=facts)
    described_class.trim(body, day)
  end

  # All three verbatim from prod, because the bar has to sit between these and
  # a clause that is doing work.
  describe "the ones that went out" do
    it "drops prod 5445" do
      expect(trim("Not much on deck from here, which is either peaceful or suspiciously peaceful."))
        .to eq("Not much on deck from here.")
    end

    it "drops prod 5248" do
      expect(trim("Then tonight's got meatballs & power Mac, which is a nice little anchor."))
        .to eq("Then tonight's got meatballs & power Mac.")
    end

    it "drops prod 5017" do
      expect(trim("Otherwise it looks nice and open for you, which is a small mercy!"))
        .to eq("Otherwise it looks nice and open for you!")
    end
  end

  # Rocco, 7 Oct 2026: "He's started doing the extra bits again. 'if you enjoy
  # being bullied by bins'".
  #
  # With the `which` form caught, the same empty clause came back as a trailing
  # conditional aimed at the reader. One briefing carried three of them, hung
  # off the chores, the evening and the forecast in turn - which is the tic TONE
  # names, one observation per item rather than one per message.
  describe "the shape it moved to" do
    it "drops the one he quoted" do
      expect(trim("Nice little double-point kind of day, if you enjoy being bullied by bins."))
        .to eq("Nice little double-point kind of day.")
    end

    it "drops one that only says how to feel about the day" do
      expect(trim("The afternoon is wide open, if you like that sort of thing."))
        .to eq("The afternoon is wide open.")
    end

    it "keeps a condition that names something from the day" do
      body = "Dinner's late, if the meatballs hold out."

      expect(trim(body)).to eq(body)
    end

    it "keeps one carrying a figure" do
      body = "You could take the run early, if 6:15 suits you."

      expect(trim(body)).to eq(body)
    end

    # A restrictive one is the sentence's own grammar, the same as `which`.
    it "keeps one with no comma in front of it" do
      body = "Take the bag if you're heading out."

      expect(trim(body)).to eq(body)
    end
  end

  # The expensive direction. A clause carrying something is a clause somebody
  # wanted, and losing one is worse than leaving a flourish in.
  describe "the ones that stay" do
    it "keeps a clause with a figure in it" do
      body = "Eye Follow Up at 11:40, which is a 22 minute drive."

      expect(trim(body)).to eq(body)
    end

    it "keeps a clause that names something from the day" do
      body = "Dinner's late, which is meatballs anyway."

      expect(trim(body)).to eq(body)
    end

    it "keeps a long one, whatever the words are" do
      body = "It's quiet, which gives you the whole afternoon back if you want to take the run early."

      expect(trim(body)).to eq(body)
    end

    # A restrictive "which" with no comma is the sentence's own grammar.
    it "keeps one with no comma in front of it" do
      body = "Take the bag which is by the door."

      expect(trim(body)).to eq(body)
    end

    it "never eats the sentence after it" do
      expect(trim("It's open, which is lovely. Game Night is still on at 7."))
        .to eq("It's open. Game Night is still on at 7.")
    end

    # A body that was nothing else has no version of itself left to hand back.
    it "leaves a body that is only the flourish alone" do
      body = ", which is lovely."

      expect(trim(body)).to eq(body)
    end
  end
end
