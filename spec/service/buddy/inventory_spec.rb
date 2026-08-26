require "rails_helper"

RSpec.describe Buddy::Inventory do
  let(:user) { create(:user) }

  let!(:basement) { create(:box, user: user, name: "Basement") }
  let!(:tool_cubes) { create(:box, user: user, name: "Tool Cubes", parent: basement) }
  let!(:batteries) { create(:box, user: user, name: "Batteries", parent: tool_cubes) }
  let!(:aa) { create(:box, user: user, name: "AA", parent: batteries) }
  let!(:c_cell) { create(:box, user: user, name: "C", parent: batteries) }
  let!(:tent) { create(:box, user: user, name: "Tent", parent: basement, notes: "4 person") }
  let!(:stakes) { create(:box, user: user, name: "Tent Stakes And Guylines", parent: basement) }

  describe ".resolve!" do
    it "takes an exact name over a longer one that merely contains it" do
      expect(described_class.resolve!(user, "Tent")).to eq(tent)
    end

    it "prefers the name the needle is most of" do
      expect(described_class.resolve!(user, "stakes")).to eq(stakes)
    end

    it "finds a box by the handle off its label" do
      expect(described_class.resolve!(user, "##{batteries.param_key}")).to eq(batteries)
    end

    it "reads 0 and 1 off a label as O and I" do
      box = create(:box, user: user, name: "Odds", param_key: "OIXY")

      expect(described_class.resolve!(user, "#01XY")).to eq(box)
    end

    it "keeps a real name ahead of a handle that happens to spell it" do
      dice = create(:box, user: user, name: "Dice", parent: basement)
      create(:box, user: user, name: "Something Else", param_key: "DICE")

      expect(described_class.resolve!(user, "Dice")).to eq(dice)
      expect(described_class.resolve!(user, "#DICE").name).to eq("Something Else")
    end

    it "forgives a typo in a name long enough to have one" do
      expect(described_class.resolve!(user, "batteries")).to eq(batteries)
      expect(described_class.resolve!(user, "batterys")).to eq(batteries)
    end

    it "does not guess at a name too short to typo" do
      expect { described_class.resolve!(user, "Z") }.to raise_error(/nothing in the inventory/)
    end

    it "asks which one when the same name is in two places" do
      create(:box, user: user, name: "Smellies", parent: basement)
      create(:box, user: user, name: "Smellies", parent: tool_cubes)

      expect { described_class.resolve!(user, "Smellies", verb: "move") }
        .to raise_error(/more than one Smellies.+Ask which one to move/m)
    end

    it "raises rather than reaching into somebody else's inventory" do
      other = create(:user)
      create(:box, user: other, name: "Their Tote")

      expect { described_class.resolve!(user, "Their Tote") }.to raise_error(/nothing in the inventory/)
    end
  end

  describe ".search" do
    it "matches the thing, not the path it sits under" do
      found = described_class.search(user: user, query: "cubes")
      expect(found[:items]).to eq([tool_cubes])
    end

    it "matches on notes" do
      found = described_class.search(user: user, query: "4 person")
      expect(found[:items]).to eq([tent])
    end

    it "narrows to one container's subtree" do
      found = described_class.search(user: user, query: "a", inside: "Batteries")
      expect(found[:items]).to contain_exactly(aa)
    end

    it "lists direct contents when there's nothing to search for" do
      found = described_class.search(user: user, inside: "Batteries")
      expect(found[:items]).to contain_exactly(aa, c_cell)
      expect(found[:container]).to eq(batteries)
    end

    it "insists on something to look for with no container" do
      expect { described_class.search(user: user) }.to raise_error(/say what to look for/)
    end

    it "answers what have I got, which had no name for the root before" do
      found = described_class.search(user: user, inside: "everything")
      expect(found[:items]).to contain_exactly(basement)
      expect(found[:container]).to be_nil
      expect(found[:root]).to be(true)
    end

    it "counts the boxes and the things in them apart" do
      counts = described_class.search(user: user, inside: "top")[:counts]
      expect(counts[:boxes]).to eq(3)   # Basement, Tool Cubes, Batteries
      expect(counts[:items]).to eq(4)   # AA, C, Tent, Tent Stakes
    end
  end

  describe ".rows" do
    it "says where a thing is, what it holds, and its notes" do
      row = described_class.rows([batteries, tent]).first
      expect(row).to eq("##{batteries.param_key} · Batteries · in Basement > Tool Cubes · holds 2 things")
    end

    it "names the top level rather than leaving the place blank" do
      expect(described_class.row(basement)).to include("in the top level")
    end

    it "counts photos" do
      tent.images.create!(user: user).file.attach(
        io: StringIO.new("\xFF\xD8fake".b), filename: "tent.jpg", content_type: "image/jpeg",
      )

      expect(described_class.row(tent.reload)).to include("1 photo")
    end
  end
end
