require "rails_helper"

RSpec.describe GameTemplate do
  let(:user) { create(:user) }

  describe ".find_by_alias" do
    it "matches an exact alias, trimmed, for old ActionEvent names" do
      template = user.game_templates.create!(name: "Parks and Potions", aliases: ["Parks & Potions"])

      expect(described_class.find_by_alias(user, "Parks & Potions")).to eq(template)
      expect(described_class.find_by_alias(user, " Parks & Potions ")).to eq(template)
    end

    it "never folds Mycelia and Mycelia Cards together" do
      mycelia = user.game_templates.create!(name: "Mycelia")
      cards = user.game_templates.create!(name: "Mycelia Cards")

      expect(described_class.find_by_alias(user, "Mycelia")).to eq(mycelia)
      expect(described_class.find_by_alias(user, "Mycelia Cards")).to eq(cards)
    end

    it "returns nil for an unknown name" do
      expect(described_class.find_by_alias(user, "Nope")).to be_nil
    end
  end

  it "rejects a duplicate name for the same user" do
    user.game_templates.create!(name: "Catan")
    dup = user.game_templates.build(name: "Catan")

    expect(dup).not_to be_valid
  end

  describe "phases" do
    let(:text) {
      <<~TEXT
        Emerge #E8A83E: Nodes Pulse, Springs Yield, [EMERGE] #E8A83E

        Swarm #D4644E (each player x2): 2, 1, 0
        Settle
      TEXT
    }

    it "reads one phase per line, with color, steps and each-player laps" do
      expect(described_class.parse_phases(text)).to eq([
        { name: "Emerge", color: "#e8a83e", steps: ["Nodes Pulse", "Springs Yield", "[EMERGE]"] },
        { name: "Swarm", color: "#d4644e", laps: 2, steps: ["2", "1", "0"] },
        { name: "Settle", steps: [] },
      ])
    end

    it "writes the lines back the way it reads them" do
      template = user.game_templates.create!(name: "Slime Colony", phases: described_class.parse_phases(text))

      expect(template.reload.phases_text).to eq(
        <<~TEXT.chomp,
          Emerge #e8a83e: Nodes Pulse, Springs Yield, [EMERGE]
          Swarm #d4644e (each player x2): 2, 1, 0
          Settle
        TEXT
      )
    end
  end
end
