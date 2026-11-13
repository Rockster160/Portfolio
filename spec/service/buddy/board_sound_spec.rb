require "rails_helper"

RSpec.describe Buddy::BoardSound do
  describe ".notes" do
    it "keeps each note in the shape the browser's beeps plays" do
      expect(described_class.notes([[400, 392, 0.9, "Sine"], [200, 0, 0, nil]])).to eq(
        [[400, 392.0, 0.9, "sine"], [200, 0, 0, nil]],
      )
    end

    it "reins in what a speaker can't sensibly play" do
      notes = described_class.notes([[60_000, 90_000, 4, "kazoo"], [-5, 440, 1, "sine"]])

      expect(notes).to eq([[10_000, 20_000.0, 1.0, "sine"]])
    end

    it "takes a lone note as a sound of one" do
      expect(described_class.notes([300, 440, 0.5, "square"])).to eq([[300, 440.0, 0.5, "square"]])
    end

    it "plays nothing from a name or nothing at all" do
      expect(described_class.notes("nap")).to eq([])
      expect(described_class.notes(nil)).to eq([])
    end
  end
end
