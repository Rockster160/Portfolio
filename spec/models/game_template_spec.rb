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

  it "stores scoring and win as their own enum without colliding with AR methods" do
    template = user.game_templates.create!(name: "Co-op Game", scoring: :table, win: :none)

    expect(template.scoring).to eq("table")
    expect(template.win).to eq("none")
  end
end
