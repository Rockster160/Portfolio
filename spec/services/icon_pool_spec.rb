require "rails_helper"

RSpec.describe IconPool do
  before { described_class.reset! }

  describe ".best_match" do
    # Each row is a ranking rule: curated aliases, exact name over keyword,
    # irregular plurals and verb-form variants, later tokens weighing more.
    it "ranks the expected icon first for each query" do
      [
        ["brush teeth",   ["🪥"]],
        ["empty bed",     ["🛏️"]],
        ["bed",           ["🛏️"]],
        ["teeth",         ["🦷"]],
        ["saving",        ["💾"]],
        ["Water Flowers", %w[🌸 🌹 🌷 🌺 🌼 💐 🌻]],
        ["death",         %w[💀 ☠️]],
        ["jolly roger",   %w[☠️ 🏴‍☠️]],
      ].each { |query, allowed|
        expect(allowed).to include(described_class.best_match(query)&.dig(:c)), query
      }

      expect(described_class.best_match("load")[:k]).to include("loading").or include("loadings")
    end

    it "returns nil when nothing clears the floor, or for a blank query" do
      ["qqqxxnonsenseword", "", nil].each { |query|
        expect(described_class.best_match(query)).to be_nil, query.inspect
      }
    end
  end

  describe ".search" do
    it "returns the full pool for a blank query (emoji first) and ranks exact names first" do
      rows = described_class.search("", limit: 5)
      expect(rows.size).to eq(5)
      expect(rows.first[:kind]).to eq(:emoji)

      expect(described_class.search("bed", limit: 3).first[:c]).to eq("🛏️")
    end
  end

  describe ".normalize" do
    it "keeps only letters and digits, so punctuation never stands between a search and a name" do
      expect(described_class.normalize("K.K.")).to eq("kk")
      expect(described_class.normalize("Jack-o'-Lantern 2")).to eq("jackolantern2")
    end
  end

  describe ".best_match_value" do
    it "returns the icon character string directly, or nil" do
      expect(described_class.best_match_value("brush teeth")).to eq("🪥")
      expect(described_class.best_match_value("qqqxxnonsenseword")).to be_nil
    end

    it "returns a hicon:<id> ref (not the raw data URL) for custom household matches" do
      user = create(:user)
      household = ChoreHousehold.create!(name: "Home", owner_user: user)
      user.update!(chore_household_id: household.id)
      icon = HouseholdIcon.create!(
        chore_household: household, uploaded_by_user: user,
        name: "Whisper", image_data: "data:image/png;base64,iVBORw0KGgo=",
        keywords: "cat",
      )

      expect(described_class.best_match_value("whisper", for_household: household)).to eq("hicon:#{icon.id}")
    end
  end
end
