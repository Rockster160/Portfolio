require "rails_helper"

# The household's own vocabulary, as rows anyone can edit, rendered into the
# system prompt.
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
    # A glossary that guesses is worse than one that stays quiet — a wrong
    # translation is invisible everywhere downstream of it.
    it "matches the term or an alias as a whole word, case-insensitively, inside a sentence", :aggregate_failures do
      whisper = term!("Whisper", "Their dog.", aliases: ["puppy", "the dog"], kind: :pet)

      ["whisper", "WHISPER", "puppy", "the dog", "did you feed the puppy yet"].each do |text|
        expect(described_class.lookup(household, text)).to eq(whisper), text
      end
      expect(described_class.lookup(household, "puppylike")).to be_nil
      expect(described_class.lookup(household, "whispering")).to be_nil
    end

    it "stays inside its own household, and is nil rather than raising without one", :aggregate_failures do
      expect(described_class.lookup(household, "muti")).to be_nil
      term!("Muti", "Medicine.")
      other = ChoreHousehold.create!(name: "Elsewhere", owner_user: create(:user))

      expect(described_class.lookup(other, "muti")).to be_nil
      expect(described_class.lookup(nil, "muti")).to be_nil
    end
  end

  describe "the starter set (Buddy::GlossarySeed)" do
    it "plants the terms and finds them by alias" do
      Buddy::GlossarySeed.plant!(household)

      expect(HouseholdGlossaryTerm.where(chore_household: household).count).to eq(Buddy::GlossarySeed::TERMS.length)
      expect(HouseholdGlossaryTerm.lookup(household, "set quiet mode for an hour")&.term).to be_present
    end

    it "leaves a term the household already edited alone" do
      mine = HouseholdGlossaryTerm.create!(chore_household: household, term: "Muti", meaning: "My own wording.")

      planted = Buddy::GlossarySeed.plant!(household)

      expect(mine.reload.meaning).to eq("My own wording.")
      expect(planted).to eq(Buddy::GlossarySeed::TERMS.length - 1)
    end
  end

  describe "the prompt block" do
    it "carries each term and its aliases into the prompt in place of the placeholder", :aggregate_failures do
      term!("Whisper", "Their dog.", aliases: ["puppy"], kind: :pet)

      prompt = Buddy::Personality.for(user, conversation: convo)

      expect(prompt).to include("### The household's own words")
      expect(prompt).to include("**Whisper** = Their dog.")
      expect(prompt).to match(/Whisper.*"puppy"/)
      expect(prompt).not_to include("{{GLOSSARY_BLOCK}}")
    end

    it "collapses to nothing when the household has no glossary, or there is no household", :aggregate_failures do
      expect(Buddy::Personality.for(user, conversation: convo)).not_to include("The household's own words")

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

    it "teaches a new word, with an undo that unlearns it" do
      result, = define({ term: "Skottel", meaning: "The gas braai pan.", kind: :thing })

      expect(described_class.lookup(household, "skottel").meaning).to eq("The gas braai pan.")

      expect(Buddy::Reverter.reversible?(result[:revert])).to be(true)
      Buddy::Reverter.call(result[:revert])
      expect(described_class.lookup(household, "skottel")).to be_nil
    end

    it "splits comma-separated aliases" do
      define({ term: "Braai", meaning: "A barbecue.", aliases: "barbie, the grill" })

      expect(described_class.lookup(household, "the grill").term).to eq("Braai")
    end

    it "updates an existing word rather than making a second one, with an undo that restores it" do
      term!("Muti", "Medicine.")

      result, = define({ term: "muti", meaning: "Medicine, specifically the daily pills." })

      expect(described_class.where(chore_household: household).where("LOWER(term) = 'muti'").count).to eq(1)

      Buddy::Reverter.call(result[:revert])
      expect(described_class.lookup(household, "muti").meaning).to eq("Medicine.")
    end

    # "oh, and I call it X too" is additive. Replacing the list would silently
    # drop the aliases that are the reason the entry works at all.
    it "adds to the alias list on update instead of replacing it" do
      term!("Whisper", "Their dog.", aliases: ["puppy"])

      define({ term: "Whisper", meaning: "Their dog.", aliases: "wisp" })

      expect(described_class.lookup(household, "puppy")).to be_present
      expect(described_class.lookup(household, "wisp")).to be_present
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

    it "drops a word, fuzzily matched, with an undo that puts it back" do
      term!("Skottel", "The gas braai pan.", aliases: ["skottel braai"])

      result = forget({ term: "skottel braai" })

      expect(result[:term]).to eq("Skottel")
      expect(described_class.lookup(household, "skottel")).to be_nil

      Buddy::Reverter.call(result[:revert])

      expect(described_class.lookup(household, "skottel").meaning).to eq("The gas braai pan.")
    end

    it "says which word it couldn't find" do
      tool = Buddy::Tools[:forget_term]

      expect { tool[:confirm].call({ term: "nonsense" }, ctx) }.to raise_error(/nonsense/)
    end
  end
end
