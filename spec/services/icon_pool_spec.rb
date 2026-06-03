require "rails_helper"

RSpec.describe IconPool do
  before { described_class.reset! }

  describe ".best_match" do
    it "returns the toothbrush for 'brush teeth'" do
      match = described_class.best_match("brush teeth")
      expect(match&.dig(:c)).to eq("🪥")
    end

    it "prefers the empty bed for 'empty bed' (curated alias)" do
      match = described_class.best_match("empty bed")
      expect(match&.dig(:c)).to eq("🛏️")
    end

    it "prefers the empty bed for 'bed' alone (exact-name beats keyword-exact)" do
      # 🛏️ "bed" name === query → 5
      # 🛌 "person in bed" — normalized name "personinbed", keyword "bed" exact → 4
      match = described_class.best_match("bed")
      expect(match&.dig(:c)).to eq("🛏️")
    end

    it "returns nil when nothing clears the floor" do
      expect(described_class.best_match("qqqxxnonsenseword")).to be_nil
    end

    it "returns nil for blank queries" do
      expect(described_class.best_match("")).to be_nil
      expect(described_class.best_match(nil)).to be_nil
    end

    it "handles irregular plurals via variants ('teeth' reaches 'tooth')" do
      # variants("teeth") → ["teeth", "tooth", …] so the bare 🦷 (name "tooth")
      # gets an exact-name hit even though no row stores "teeth" directly.
      match = described_class.best_match("teeth")
      expect(match&.dig(:c)).to eq("🦷")
    end
  end

  describe ".search" do
    it "returns the full pool for a blank query (emoji first)" do
      rows = described_class.search("", limit: 5)
      expect(rows.size).to eq(5)
      expect(rows.first[:kind]).to eq(:emoji)
    end

    it "ranks exact-name match above keyword match" do
      rows = described_class.search("bed", limit: 3)
      expect(rows.first[:c]).to eq("🛏️")
    end
  end

  describe ".best_match_value" do
    it "returns the icon character string directly" do
      expect(described_class.best_match_value("brush teeth")).to eq("🪥")
    end

    it "returns nil when no match" do
      expect(described_class.best_match_value("qqqxxnonsenseword")).to be_nil
    end
  end
end
