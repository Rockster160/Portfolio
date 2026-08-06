require "rails_helper"

# The household's own vocabulary, moved out of the system prompt and into rows
# anyone can edit. The prompt used to carry five hardcoded bullets; adding a
# sixth meant a deploy, so in practice nobody added one and the companion kept
# mishearing the same handful of words.
RSpec.describe HouseholdGlossaryTerm do
  let(:user)      { User.me }
  let(:household) { user.chore_household }
  let(:convo)     { user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current) }

  def ctx = Buddy::ToolContext.new(user)

  def term!(term, meaning, aliases: [], kind: nil, notes: nil)
    described_class.create!(
      chore_household: household, term: term, meaning: meaning,
      aliases: aliases, kind: kind, notes: notes
    )
  end

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(ActionCable.server).to receive(:broadcast)
    HouseholdGlossaryTerm.where(chore_household: household).delete_all
  end

  describe ".lookup" do
    it "matches the term itself, case-insensitively" do
      whisper = term!("Whisper", "Their dog.", aliases: ["puppy", "the dog"], kind: :pet)

      expect(described_class.lookup(household, "whisper")).to eq(whisper)
      expect(described_class.lookup(household, "WHISPER")).to eq(whisper)
    end

    it "matches an alias" do
      whisper = term!("Whisper", "Their dog.", aliases: ["puppy", "the dog"], kind: :pet)

      expect(described_class.lookup(household, "puppy")).to eq(whisper)
      expect(described_class.lookup(household, "the dog")).to eq(whisper)
    end

    it "finds a term inside a sentence" do
      whisper = term!("Whisper", "Their dog.", aliases: ["puppy"], kind: :pet)

      expect(described_class.lookup(household, "did you feed the puppy yet")).to eq(whisper)
    end

    # A glossary that guesses is worse than one that stays quiet — a wrong
    # translation is invisible everywhere downstream of it.
    it "does not match a word that merely contains the term" do
      term!("Whisper", "Their dog.", aliases: ["puppy"], kind: :pet)

      expect(described_class.lookup(household, "puppylike")).to be_nil
      expect(described_class.lookup(household, "whispering")).to be_nil
    end

    it "stays inside its own household" do
      term!("Muti", "Medicine.")
      other = ChoreHousehold.create!(name: "Elsewhere", owner_user: create(:user))

      expect(described_class.lookup(other, "muti")).to be_nil
    end

    it "is nil for a household that has none, rather than raising" do
      expect(described_class.lookup(household, "muti")).to be_nil
      expect(described_class.lookup(nil, "muti")).to be_nil
    end
  end

  # The starter set lives in the app rather than in the migration that first
  # ran it, so it can be asserted on here and re-planted for a new household.
  describe "the starter set (Buddy::GlossarySeed)" do
    before { Buddy::GlossarySeed.plant!(household) }

    it "carries the terms that used to be hardcoded in the prompt" do
      names = HouseholdGlossaryTerm.where(chore_household: household).pluck(:term)

      expect(names).to include("Muti", "Boot", "Whisper", "Fae", "Puppy Up", "Puppy Down")
    end

    it "carries the plunge, which was never in the prompt at all" do
      plunge = HouseholdGlossaryTerm.lookup(household, "the plunge")

      expect(plunge.meaning).to include("Horsetail Falls")
      expect(plunge.kind).to eq("place")
    end

    # eve.md teaches the companion to SPEAK these; nothing taught it to
    # understand them, and bakkie is the one that actually bites — it means a
    # pickup truck to everybody outside this house.
    it "carries Eve's vocabulary, including the actively misleading one" do
      bakkie = HouseholdGlossaryTerm.lookup(household, "bakkie")

      expect(bakkie.meaning).to include("plastic tub")
      expect(bakkie.notes).to include("not a pickup truck")
      expect(HouseholdGlossaryTerm.lookup(household, "now now").meaning).to include("NOT immediately")
    end

    it "leaves a term the household already edited alone" do
      HouseholdGlossaryTerm.where(chore_household: household).delete_all
      mine = HouseholdGlossaryTerm.create!(chore_household: household, term: "Muti", meaning: "My own wording.")

      planted = Buddy::GlossarySeed.plant!(household)

      expect(mine.reload.meaning).to eq("My own wording.")
      expect(planted).to eq(Buddy::GlossarySeed::TERMS.length - 1)
    end
  end

  describe "the prompt block" do
    let(:prompt) { Buddy::Personality.for(user, conversation: convo) }

    before { Buddy::GlossarySeed.plant!(household) }

    it "renders the glossary instead of the placeholder" do
      expect(prompt).to include("### The household's own words")
      expect(prompt).not_to include("{{GLOSSARY_BLOCK}}")
    end

    it "groups by kind and lists aliases" do
      expect(prompt).to include("**Pets**")
      expect(prompt).to include("**Whisper** = Their dog.")
      expect(prompt).to match(/Whisper.*Also:.*"puppy"/)
    end

    it "points an unknown word at define_term rather than at a guess" do
      expect(prompt).to include("ask what it means rather than guessing")
      expect(prompt).to include("`define_term`")
    end

    it "leaves the app's own shorthand where it was" do
      # Timers and pebbles are behavioral rules, not vocabulary — they reference
      # tool names and context sections, so they stayed in the static prose.
      expect(prompt).to include("is a TIMER")
      expect(prompt).to include("N pebbles")
    end

    it "collapses to nothing when the household has no glossary" do
      described_class.where(chore_household: household).delete_all

      expect(Buddy::Personality.for(user, conversation: convo)).not_to include("The household's own words")
    end

    it "collapses to nothing for someone with no household" do
      loner = create(:user)
      theirs = loner.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

      expect(Buddy::Personality.for(loner, conversation: theirs)).not_to include("{{GLOSSARY_BLOCK}}")
    end
  end

  describe "define_term" do
    def define(payload)
      tool = Buddy::Tools[:define_term]
      confirm = tool[:confirm].call(payload, ctx)
      [tool[:execute].call(payload.merge(confirm[:resolved]), ctx), confirm]
    end

    it "teaches a new word" do
      result, confirm = define({ term: "Skottel", meaning: "The gas braai pan.", kind: :thing })

      expect(confirm[:summary]).to eq("Teach the house **Skottel**?")
      expect(result[:verb]).to eq("Learned")
      expect(described_class.lookup(household, "skottel").meaning).to eq("The gas braai pan.")
    end

    it "splits comma-separated aliases" do
      define({ term: "Braai", meaning: "A barbecue.", aliases: "barbie, the grill" })

      expect(described_class.lookup(household, "the grill").term).to eq("Braai")
    end

    it "updates an existing word rather than making a second one" do
      term!("Muti", "Medicine.")

      result, confirm = define({ term: "muti", meaning: "Medicine, specifically the daily pills." })

      expect(confirm[:summary]).to eq("Update **Muti**?")
      expect(result[:verb]).to eq("Updated")
      expect(described_class.where(chore_household: household).where("LOWER(term) = 'muti'").count).to eq(1)
    end

    # "oh, and I call it X too" is additive. Replacing the list would silently
    # drop the aliases that are the reason the entry works at all.
    it "adds to the alias list on update instead of replacing it" do
      term!("Whisper", "Their dog.", aliases: ["puppy"])

      define({ term: "Whisper", meaning: "Their dog.", aliases: "wisp" })

      expect(described_class.lookup(household, "puppy")).to be_present
      expect(described_class.lookup(household, "wisp")).to be_present
    end

    it "hands back an undo that unlearns the word" do
      result, = define({ term: "Skottel", meaning: "The gas braai pan." })

      expect(Buddy::Reverter.reversible?(result[:revert])).to be(true)
      Buddy::Reverter.call(result[:revert])
      expect(described_class.lookup(household, "skottel")).to be_nil
    end

    it "hands back an undo that restores the old meaning on an update" do
      term!("Muti", "Medicine.")
      result, = define({ term: "Muti", meaning: "Something else entirely." })

      Buddy::Reverter.call(result[:revert])

      expect(described_class.lookup(household, "muti").meaning).to eq("Medicine.")
    end

    it "refuses a word with no meaning" do
      tool = Buddy::Tools[:define_term]

      expect { tool[:confirm].call({ term: "Blep", meaning: " " }, ctx) }.to raise_error(/no meaning/)
    end
  end

  describe "forget_term" do
    def forget(payload)
      tool = Buddy::Tools[:forget_term]
      confirm = tool[:confirm].call(payload, ctx)
      tool[:execute].call(payload.merge(confirm[:resolved]), ctx)
    end

    it "drops a word, fuzzily matched" do
      term!("Skottel", "The gas braai pan.", aliases: ["skottel braai"])

      result = forget({ term: "skottel braai" })

      expect(result[:term]).to eq("Skottel")
      expect(described_class.lookup(household, "skottel")).to be_nil
    end

    it "hands back an undo that puts it back" do
      term!("Skottel", "The gas braai pan.")

      result = forget({ term: "Skottel" })
      Buddy::Reverter.call(result[:revert])

      expect(described_class.lookup(household, "skottel").meaning).to eq("The gas braai pan.")
    end

    it "says which word it couldn't find" do
      tool = Buddy::Tools[:forget_term]

      expect { tool[:confirm].call({ term: "nonsense" }, ctx) }.to raise_error(/nonsense.*isn't in the glossary/)
    end
  end
end
