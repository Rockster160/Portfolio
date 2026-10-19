require "rails_helper"

RSpec.describe Jil::Schema do
  let(:owner) { User.me }
  let(:other) { FactoryBot.create(:user) }

  def classes_in(text)
    text.to_s.lines.filter_map { |line| line[/\A\*?\[(\w+)\]/, 1] }
  end

  describe ".for" do
    it "hides the owner-only classes from everyone else" do
      expect(classes_in(described_class.for(other)))
        .not_to include("Tesla", "TeslaStartOptions", "Mac", "Interview")
    end

    it "keeps them for the owner" do
      expect(classes_in(described_class.for(owner)))
        .to include("Tesla", "TeslaStartOptions", "Mac", "Interview")
    end

    it "hides them from a logged-out schema request" do
      expect(classes_in(described_class.for(nil))).not_to include("Mac")
    end

    it "leaves the ungated classes alone for everyone" do
      mine = classes_in(described_class.for(owner))
      theirs = classes_in(described_class.for(other))

      expect(theirs).to include("Global", "Hash", "Array", "Chore", "Agenda")
      expect(mine - theirs).to contain_exactly("Tesla", "TeslaStartOptions", "Mac", "Interview")
    end

    # The gate is a marker for this filter, not part of the language — it must
    # not reach the editor's parser.
    it "strips the gate marker from the text it emits" do
      expect(described_class.for(owner)).to include("[Tesla]\n")
      expect(described_class.for(owner)).not_to include("@me")
    end

    it "drops a gated class's methods along with its header" do
      expect(described_class.for(other)).not_to include("#unlockDoors")
      expect(described_class.for(owner)).to include("#unlockDoors")
    end

    it "resumes emitting at the next ungated class" do
      # [Trip] follows [TeslaStartOptions]; a filter that swallowed the rest of
      # the file after a gated block would take it too.
      expect(classes_in(described_class.for(other))).to include("Trip")
    end
  end

  describe "keep:" do
    it "passes a named class through the gate" do
      expect(classes_in(described_class.for(other, keep: %w[Tesla]))).to include("Tesla")
    end

    it "keeps only what was named" do
      kept = classes_in(described_class.for(other, keep: %w[Tesla]))

      expect(kept).to include("Tesla")
      expect(kept).not_to include("Mac")
    end
  end

  describe "gate vocabulary" do
    # Fails closed: a typo'd gate hides a class from everyone rather than
    # quietly showing a restricted one to the household.
    it "refuses a gate name it doesn't recognize" do
      allow(File).to receive(:readlines).with(described_class::PATH).and_return(
        ["[Nonsense]@wat\n", "  #thing()::Any\n", "[Plain]\n", "  #other()::Any\n"],
      )

      expect(classes_in(described_class.for(owner))).to eq(["Plain"])
    end

    it "gates a single method without taking the class with it" do
      allow(File).to receive(:readlines).with(described_class::PATH).and_return(
        ["[Thing]\n", "  #open()::Any\n", "  #secret()::Any @me\n"],
      )

      expect(described_class.for(other)).to eq("[Thing]\n  #open()::Any\n")
      expect(described_class.for(owner)).to include("#secret()::Any")
    end

  # A Buddy alert's `who` and `face` are dropdowns of what's actually there for
  # the person writing the task, so nobody has to guess what to type.
  describe "the Buddy alert settings" do
    def alert_line(user)
      described_class.for(user).lines.find { |line| line.include?("#alert(") }
    end

    it "offers me, everyone and each household member by name" do
      housemate = create(:user, username: "Lodger")
      share_chore_household!(other, housemate)

      who = alert_line(other)[/who:\[([^\]]*)\]/, 1]
      expect(who).to start_with(%("me" "everyone"))
      expect(who).to include(%("#{other.first_name}"), %("Lodger"))
    end

    it "offers only me and everyone outside a household" do
      expect(alert_line(other)).to include(%(who:["me" "everyone"]))
    end

    it "offers every face a pet knows" do
      expect(alert_line(other)).to include(%("pounce"), %("eager"), %("hiding"))
      expect(alert_line(other)).not_to include("%")
    end
  end
  end
end
