require "rails_helper"

RSpec.describe Jil::Schema do
  let(:owner) { User.me }
  let(:other) { FactoryBot.create(:user) }

  def classes_in(text)
    text.to_s.lines.filter_map { |line| line[/\A\*?\[(\w+)\]/, 1] }
  end

  describe ".for" do
    it "shows the owner-only classes to the owner alone, leaving the ungated ones for everyone", :aggregate_failures do
      gated = %w[Tesla TeslaStartOptions Mac Interview]
      mine = classes_in(described_class.for(owner))
      theirs = classes_in(described_class.for(other))

      expect(mine).to include(*gated)
      expect(theirs).not_to include(*gated)
      expect(classes_in(described_class.for(nil))).not_to include("Mac")
      expect(theirs).to include("Global", "Hash", "Array", "Chore", "Agenda", "Trip")
      expect(mine - theirs).to contain_exactly(*gated)
    end

    it "strips the gate marker from the text it emits" do
      expect(described_class.for(owner)).to include("[Tesla]\n")
      expect(described_class.for(owner)).not_to include("@me")
    end

    it "drops a gated class's methods along with its header" do
      expect(described_class.for(other)).not_to include("#unlockDoors")
      expect(described_class.for(owner)).to include("#unlockDoors")
    end

  end

  describe "keep:" do
    it "passes only the named class through the gate" do
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

    it "offers the system faces for a face, or any name typed, beside the mood sliders" do
      expect(alert_line(other)).to include(%(face:["sleeping" "thinking" "wave" "working" *]), "warmth:Slider")
      expect(alert_line(other)).not_to include("%")
    end

    it "offers a yell their boards by name, then all, or any name typed" do
      other.byte_conversations.create!(mode: :buddy, name: "Kitchen", metadata: { "board" => true })
      yell = described_class.for(other).lines.find { |line| line.include?("#yell(") }

      expect(yell).to include(%(board:["Kitchen" "all" *]))
    end
  end
  end
end
