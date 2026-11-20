require "rails_helper"

# A briefing must not SAY a carried memory the seed never raised; being shaped
# by it is fine.
RSpec.describe Buddy::UnpromptedMemory do
  # A carried memory is only ever read for its `content` here, so the spec does
  # not need a record - and must not leak a constant to get one.
  let(:held) { Struct.new(:content) }

  let(:facts) {
    { weather: ["High 74°F, low 53°F"], today: ["9:00am · Dentist"], jobs: [] }
  }
  let(:carried) { [held.new("Be mindful about how the audit at work might affect me")] }

  def trim(body) = described_class.trim(body, carried, facts)

  it "drops the sentence that names it, and one pointing back at it", :aggregate_failures do
    [
      ["Morning! And I'm holding that audit note for you too, so you don't have to keep it in your head.", "Morning!"],
      ["High of 74 today.\n\nDentist at 9.\n\nI know the audit is on your mind.", "High of 74 today.\n\nDentist at 9."],
      ["Dentist at 9. I'm holding that audit note for you. That one's been sitting a while. High of 74.", "Dentist at 9. High of 74."],
    ].each { |body, out| expect(trim(body)).to eq(out), body }
  end

  # A gentler tone names nothing; a "that" opener only goes along with a cut;
  # and a body that was nothing else is kept whole.
  it "leaves everything else exactly as written", :aggregate_failures do
    [
      "Morning - take it easy today if you can, and leave yourself some room.",
      "Dentist at 9. That one's been on the calendar a while.",
      "I'm still holding that audit note for you.",
    ].each { |body| expect(trim(body)).to eq(body), body }

    expect(described_class.trim("Morning! High of 74 and a clear afternoon.", [], facts))
      .to eq("Morning! High of 74 and a clear afternoon.")
  end

  # If the seed carried it, the seed decided it was today's subject.
  it "allows a word the facts themselves carried" do
    body = "The audit is at 9:00am, so the morning is spoken for."
    facts_with = facts.merge(today: ["9:00am · Audit at work"])

    expect(described_class.trim(body, carried, facts_with)).to eq(body)
  end

  # The word that tips a sentence can be its lead-in, and an agenda item the
  # seed carried is the seed's subject however the sentence opens.
  it "keeps a sentence that names one of the seed's items" do
    body = "Then 3pm is Yoga at Mountain Yoga Sandy. After that, 8pm is Game Night! & dinner."
    seeded = {
      today: [
        { title: "Yoga", time: "3:00 PM" },
        { title: "Game Night! & dinner", time: "8:00 PM" },
      ],
    }
    lingering = [held.new("What happens after the audit wraps up")]

    expect(described_class.trim(body, lingering, seeded)).to eq(body)
    expect(described_class.trim("8pm is Game Night! I'm holding the wraps note for you.", lingering, seeded))
      .to eq("8pm is Game Night!")
  end

  # The always-loaded block ships on a briefing where `situation_block` does
  # not, so a preference-kind note about somebody's life is the one that can
  # actually reach one - and it takes two of its words rather than one, because
  # a preference's vocabulary is the briefing's vocabulary.
  describe "a preference memory" do
    let(:preference) { Struct.new(:content) { def kind_preference? = true } }

    def trim_pref(body, content)
      described_class.trim(body, [preference.new(content)], facts)
    end

    it "drops a sentence naming several of its words, not one sharing a single ordinary word", :aggregate_failures do
      expect(trim_pref(
        "Morning! Keeping in mind your period is about 6 days away, so a softer touch this week.",
        "Be mindful about how hormones might affect me over the next little while, with my period about 6 days away.",
      )).to eq("Morning!")

      body = "Your shopping list has four things on it."
      expect(trim_pref(body, "My list means the Ongoing TO DO list, not the old empty duplicate.")).to eq(body)
    end

    # The two-word bar is per note, so a big pool of preferences can't
    # assemble a conviction from one ordinary word in each of two notes.
    describe "several preferences at once" do
      def trim_all(body, *notes)
        described_class.trim(body, notes.map { |n| preference.new(n) }, facts)
      end

      it "does not convict on one word each from different notes, however many there are" do
        body = "Morning! That fridge-leftovers thought is still sitting there if you want to get back to it."
        notes = [
          "When something is sitting in the pile, hold it in your head for a moment.",
          "When I get distracted, nudge me back to the task I was doing.",
          "Unfinished things should stay at the forefront so they are not forgotten.",
          "Keep the project list short and tell me what is next.",
        ]

        expect(trim_all(body, *notes)).to eq(body)
      end

      # And the guard itself is untouched: two words of ONE note still convicts,
      # with others sitting in the pool alongside it.
      it "still drops a sentence that names one note twice over" do
        body = "Morning! The tribunal hearing is close now, so a softer touch this week."

        kept = trim_all(
          body,
          "Be mindful about how the tribunal hearing might be weighing on me.",
          "When I get distracted, nudge me back to the task I was doing.",
          "Keep the project list short and tell me what is next.",
        )

        expect(kept).to eq("Morning!")
      end

      # A word two notes both use is ordinary by demonstration, so it stops
      # counting for either of them - the same subtraction the facts get.
      it "ignores a word two notes have in common" do
        body = "Morning! The recycling is still sitting by the door."

        kept = trim_all(
          body,
          "Things sitting around bother me.",
          "I hate sitting still for long.",
        )

        expect(kept).to eq(body)
      end
    end
  end

  # The words in a carried memory are the most private thing this system holds.
  # They are read to decide a drop and never written anywhere.
  it "keeps the memory's words out of the log" do
    allow(Rails.logger).to receive(:info)

    trim("Morning! I'm holding that audit note for you.")

    expect(Rails.logger).to have_received(:info) { |line| expect(line).not_to include("audit") }
  end

  # A stash thought held back by STASH_SPACING can still come off yesterday's
  # briefing in the scrollback; the words are the only place to catch it.
  describe "a stash thought the spacing withheld" do
    let(:fridge) {
      Struct.new(:content, :kind_preference?).new(
        "leftover food in my fridge that needs to be eaten, starting with pizza for lunch, " \
        "then steak, then Cafe Rio",
        false,
      )
    }
    let(:bare) { { due: [{ fire_at: "7pm", body: "Check the front flower bed." }], stash: [] } }

    def withheld(body) = described_class.trim(body, [fridge], bare)

    it "drops the line that reaches back for it" do
      body = "Mooooorning! Hope the fridge mission is feeling a bit more tamed now."

      expect(withheld(body)).to eq("Mooooorning!")
    end

    # The note says "...fridge THAT needs to be eaten"; the stoplist keeps
    # grammar words from convicting.
    it "is not a veto on every sentence containing the word that", :aggregate_failures do
      [
        "Mooooorning! Check the front flower bed at 7pm today, that one's on deck.",
        "Hi! Rain is due on Tuesday, so that's the bit worth keeping one eye on!",
      ].each { |body| expect(withheld(body)).to eq(body) }
    end

    # The morning it IS floated, the seed decided it was the subject.
    it "allows it on the morning the prompt actually floats it" do
      body = "Morning! That fridge pile is still sitting there if you want a run at it."
      floated = bare.merge(stash: [{ idea: "leftover food in my fridge", age: "3 weeks" }])

      expect(described_class.trim(body, [fridge], floated)).to eq(body)
    end
  end

  describe "a stashed thought the seed handed over" do
    let(:preference) { Struct.new(:content) { def kind_preference? = true } }
    let(:pile_note) { preference.new("My ideas pile is where thoughts go sitting until I want them") }
    let(:floated) { facts.merge(stash: [{ id: 196, idea: "Freezer breakfast prep", waiting: "9 weeks" }]) }

    it "keeps the sentence naming it, and the question after it" do
      body = "Morning, Eve! Snow day today.\n\n**Freezer breakfast prep** has been on your mind for " \
             "about 9 weeks now, and it's still sitting in your ideas pile. Want me to pull it up, " \
             "or leave it be for now?"

      expect(described_class.trim(body, [pile_note], floated)).to eq(body)
    end

    it "still drops a sentence using the note's words that names no seeded thought" do
      body = "Morning, Eve! Your ideas pile is still sitting there."

      expect(described_class.trim(body, [pile_note], floated)).to eq("Morning, Eve!")
    end
  end

  describe "a chore the seed carried" do
    let(:note) {
      Struct.new(:content, :kind_preference?).new(
        "Jil needs explicit daytime context when scheduling time-based things.",
        false,
      )
    }
    let(:seeded) {
      {
        jobs:    [{ name: "Refill Kitty Food", due_today: true }, { name: "Gather Bins", group: "Trash" }],
        weather: { notable: "snow" },
      }
    }

    def chores(body) = described_class.trim(body, [note], seeded)

    it "keeps a sentence naming one however it is worded", :aggregate_failures do
      [
        "Morning! Kitty food needs a refill today, and Fae will want that sorted.",
        "Morning! It's trash day, so the bins need to go out.",
      ].each { |body| expect(chores(body)).to eq(body), body }
    end

    it "still drops a sentence naming the note and no chore" do
      expect(chores("Morning! Jil still needs that daytime context.")).to eq("Morning!")
    end
  end

  # A blank line starts a new beat, so a sentence opening one points back at
  # nothing that was cut before it.
  it "keeps a paragraph opening with \"it\" after a cut" do
    body = "Morning!\n\nI'm holding that audit note for you.\n\nIt's snowing today, so bundle up."

    expect(trim(body)).to eq("Morning!\n\nIt's snowing today, so bundle up.")
  end

  it "is not a veto on a sentence for sharing a preposition with a carried memory", :aggregate_failures do
    held_back = [held.new("Worried about what happens before the review")]
    [
      "Bring the trash cans in today. It's snowing, so get that done before it gets slushy.",
      "An older thought is waiting. It's been about 12 weeks, so it might be worth picking back up.",
    ].each { |body| expect(described_class.trim(body, held_back, facts)).to eq(body), body }
  end
end
