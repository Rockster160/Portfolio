require "rails_helper"

RSpec.describe MealBuilder do
  let(:user) { create(:user) }
  let(:builder) { described_class.create!(user: user, name: "Food", items: []) }

  def added(name, cal)
    builder.add_item!(category: "Food", name: name, cal: cal)
    builder.reload.items.last.slice(:name, :cal)
  end

  describe "#add_item!" do
    it "adds one of something logged several at once" do
      expect(added("Sausage Roll x5", 800)).to eq(name: "Sausage Roll", cal: 160)
    end

    it "reads the count either side of the name", :aggregate_failures do
      expect(added("2x Taco", 450)).to eq(name: "Taco", cal: 225)
      expect(added("Donut ×3", 1000)).to eq(name: "Donut", cal: 333)
    end

    it "keeps a plate whole when it lists its parts" do
      expect(added("Fried Egg x3, White Toast x2", 820)).to eq(name: "Fried Egg x3, White Toast x2", cal: 820)
    end

    it "leaves a name with no count alone" do
      expect(added("Golden Curry and Rice", 780)).to eq(name: "Golden Curry and Rice", cal: 780)
    end

    it "doesn't list the single one twice" do
      added("Sausage Roll", 160)
      builder.add_item!(category: "Food", name: "Sausage Roll x2", cal: 320)

      expect(builder.reload.items.count { |item| item[:name] == "Sausage Roll" }).to eq(1)
    end
  end
end
