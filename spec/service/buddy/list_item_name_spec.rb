require "rails_helper"

# Prod 1236: "a chicken salad for mom" landed on the list verbatim, article and
# all, sitting under "Trail Mix" and "Protein Shakes".
RSpec.describe Buddy::ListItemName do
  let(:user) { create(:user) }
  let(:list) { create(:list, user: user, name: "Groceries") }

  describe ".tidy" do
    it "drops a leading article" do
      list.list_items.create!(name: "Trail Mix")

      expect(described_class.tidy("a chicken salad for mom", list: list)).to eq("Chicken salad for mom")
      expect(described_class.tidy("an avocado", list: list)).to eq("Avocado")
      expect(described_class.tidy("the good soap", list: list)).to eq("Good soap")
      expect(described_class.tidy("some paper towels", list: list)).to eq("Paper towels")
    end

    it "leaves a name that never had one alone, capitalization included" do
      list.list_items.create!(name: "Trail Mix")

      expect(described_class.tidy("oat milk", list: list)).to eq("oat milk")
      expect(described_class.tidy("Protein Shakes", list: list)).to eq("Protein Shakes")
    end

    it "keeps a word that only starts with an article" do
      expect(described_class.tidy("anchovies", list: list)).to eq("anchovies")
      expect(described_class.tidy("theraflu", list: list)).to eq("theraflu")
    end

    it "leaves a title alone" do
      expect(described_class.tidy("The Office", list: list)).to eq("The Office")
      expect(described_class.tidy("A Christmas Carol", list: list)).to eq("A Christmas Carol")
      # Still an article when what follows isn't part of a name.
      expect(described_class.tidy("The good soap", list: list)).to eq("Good soap")
    end

    it "follows a lowercase list's own style" do
      list.list_items.create!(name: "oat milk")
      list.list_items.create!(name: "bananas")

      expect(described_class.tidy("a chicken salad", list: list)).to eq("chicken salad")
    end

    it "capitalizes on an empty list" do
      expect(described_class.tidy("a chicken salad", list: list)).to eq("Chicken salad")
    end
  end

  describe "through add_list_item" do
    it "puts the tidied name on the row, the checkbox, and the record" do
      tool    = Buddy::Tools[:add_list_item]
      ctx     = Buddy::ToolContext.new(user)
      list.list_items.create!(name: "Trail Mix")

      confirm = tool[:confirm].call({ list: "Groceries", item: "a chicken salad for mom" }, ctx)
      merged  = { list: "Groceries", item: "a chicken salad for mom" }.merge(confirm[:resolved])

      expect(confirm[:summary]).to eq("Add Chicken salad for mom to Groceries?")
      expect(tool[:label].call(merged, ctx)[:title]).to eq("Chicken salad for mom")

      tool[:execute].call(merged, ctx)
      expect(list.list_items.reload.map(&:name)).to include("Chicken salad for mom")
    end
  end
end
