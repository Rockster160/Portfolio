require "rails_helper"

RSpec.describe ChoreCreditButton do
  let(:household) { create(:chore_household) }
  let(:owner)     { create(:user, chore_household_id: household.id) }
  let(:mate)      { create(:user, chore_household_id: household.id) }
  let(:chore)     { create(:chore, created_by_user: owner, chore_household_id: household.id, name: "Dishes") }

  def button(**attrs)
    described_class.new({
      chore_household: household,
      created_by_user: owner,
      chore:           chore,
      credit_user:     mate,
      tags:            ["Shared"],
      label:           "Dishes, by mate",
      color:           "#6366F1",
    }.merge(attrs))
  end

  describe "validation" do
    it "accepts a well-formed button" do
      expect(button).to be_valid
    end

    it "needs a label" do
      expect(button(label: "")).not_to be_valid
    end

    it "refuses a chore from another household" do
      other = create(:chore, created_by_user: create(:user), name: "Theirs")
      expect(button(chore: other)).not_to be_valid
    end

    it "refuses crediting someone outside the household" do
      outsider = create(:user)
      expect(button(credit_user: outsider)).not_to be_valid
    end
  end

  describe "grouping" do
    it "matches a group case-insensitively and lists its groups" do
      b = button.tap(&:save!)
      expect(described_class.tagged("shared")).to include(b)
      expect(described_class.tag_names).to eq(["Shared"])
    end

    it "matches on ANY of several groups, and a board watching any of them" do
      b = button(tags: ["Shared", "Kitchen"]).tap(&:save!)
      expect(described_class.tagged("kitchen")).to include(b)
      expect(described_class.for_board(["Garage", "shared"])).to include(b)
      expect(described_class.tagged("Garage")).not_to include(b)
    end
  end

  describe "#board_item" do
    it "draws as a stateless credit circle carrying its colour and targets" do
      item = button.board_item
      expect(item[:kind]).to eq(:credit)
      expect(item[:short_name]).to eq("Dishes, by mate")
      expect(item[:color]).to eq("#6366F1")
      expect(item[:chore_id]).to eq(chore.id)
      expect(item[:credit_user_id]).to eq(mate.id)
      expect(item).not_to have_key(:progress_count)
    end
  end
end
