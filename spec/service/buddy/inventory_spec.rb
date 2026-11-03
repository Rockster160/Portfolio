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
    it "ranks exact names, then the name the needle is most of, then handles, then typos", :aggregate_failures do
      odds = create(:box, user: user, name: "Odds", param_key: "OIXY")
      dice = create(:box, user: user, name: "Dice", parent: basement)
      create(:box, user: user, name: "Something Else", param_key: "DICE")

      [
        # An exact name over a longer one that merely contains it.
        ["Tent", tent],
        ["stakes", stakes],
        ["##{batteries.param_key}", batteries],
        # 0 and 1 off a label read as O and I.
        ["#01XY", odds],
        # A real name ahead of a handle that happens to spell it.
        ["Dice", dice],
        ["batteries", batteries],
        ["batterys", batteries],
      ].each do |needle, expected|
        expect(described_class.resolve!(user, needle)).to eq(expected), needle
      end
      expect(described_class.resolve!(user, "#DICE").name).to eq("Something Else")
    end

    it "raises rather than guessing at a short name, picking between two, or reaching into someone else's", :aggregate_failures do
      create(:box, user: user, name: "Smellies", parent: basement)
      create(:box, user: user, name: "Smellies", parent: tool_cubes)
      create(:box, user: create(:user), name: "Their Tote")

      expect { described_class.resolve!(user, "Z") }.to raise_error(/nothing in the inventory/)
      expect { described_class.resolve!(user, "Smellies", verb: "move") }.to raise_error(/more than one Smellies/)
      expect { described_class.resolve!(user, "Their Tote") }.to raise_error(/nothing in the inventory/)
    end
  end

  describe ".search" do
    it "matches the thing or its notes, not the path, and narrows to a subtree", :aggregate_failures do
      expect(described_class.search(user: user, query: "cubes")[:items]).to eq([tool_cubes])
      expect(described_class.search(user: user, query: "4 person")[:items]).to eq([tent])
      expect(described_class.search(user: user, query: "a", inside: "Batteries")[:items]).to contain_exactly(aa)
      expect { described_class.search(user: user) }.to raise_error(RuntimeError)
    end

    it "lists direct contents of a container, or of the root, with boxes and things counted apart", :aggregate_failures do
      found = described_class.search(user: user, inside: "Batteries")
      expect(found[:items]).to contain_exactly(aa, c_cell)
      expect(found[:container]).to eq(batteries)

      found = described_class.search(user: user, inside: "everything")
      expect(found[:items]).to contain_exactly(basement)
      expect(found[:container]).to be_nil
      expect(found[:root]).to be(true)

      counts = described_class.search(user: user, inside: "top")[:counts]
      expect(counts[:boxes]).to eq(3)   # Basement, Tool Cubes, Batteries
      expect(counts[:items]).to eq(4)   # AA, C, Tent, Tent Stakes
    end
  end

  describe ".rows" do
    it "leads with the handle and says where a thing is, what it holds, and its photos", :aggregate_failures do
      tent.images.create!(user: user).file.attach(
        io: StringIO.new("\xFF\xD8fake".b), filename: "tent.jpg", content_type: "image/jpeg",
      )

      expect(described_class.rows([batteries]).first).to eq(
        "##{batteries.param_key} · Batteries · in Basement > Tool Cubes · holds 2 things",
      )
      expect(described_class.row(basement)).to include("in the top level")
      expect(described_class.row(tent.reload)).to include("1 photo")
    end
  end
end
