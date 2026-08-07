require "rails_helper"

RSpec.describe Chore, "priority" do
  let(:user) { create(:user) }

  it "defaults to normal" do
    chore = create(:chore, created_by_user: user)
    expect(chore.priority).to eq("normal")
    expect(chore).to be_priority_normal
  end

  it "stores descending integers so higher = more urgent" do
    expect(described_class.priorities.values_at("critical", "high", "normal", "low", "none"))
      .to eq([4, 3, 2, 1, 0])
  end

  it "orders by the raw column with critical first" do
    none     = create(:chore, created_by_user: user, priority: :none)
    critical = create(:chore, created_by_user: user, priority: :critical)
    normal   = create(:chore, created_by_user: user, priority: :normal)

    ordered = described_class.where(id: [none, critical, normal]).order(priority: :desc).to_a
    expect(ordered).to eq([critical, normal, none])
  end

  describe ".priority_key" do
    it "normalizes casing and whitespace" do
      expect(described_class.priority_key(" Critical ")).to eq("critical")
      expect(described_class.priority_key(:high)).to eq("high")
    end

    it "returns nil for anything that isn't a level, rather than defaulting" do
      expect(described_class.priority_key("urgent")).to be_nil
      expect(described_class.priority_key("")).to be_nil
      expect(described_class.priority_key(nil)).to be_nil
    end
  end

  it "rides along on the Jil trigger payload" do
    chore = create(:chore, created_by_user: user, priority: :high)
    expect(chore.jil_attrs(action: :updated)[:priority]).to eq("high")
  end

  it "is serialized with both the name and the sortable rank" do
    chore = create(:chore, created_by_user: user, priority: :critical)
    json = ChoreSerializer.new(chore, viewer: user).as_json

    expect(json[:priority]).to eq("critical")
    expect(json[:priority_rank]).to eq(4)
  end
end
