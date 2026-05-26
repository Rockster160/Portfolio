require "rails_helper"

RSpec.describe GoogleCalendar::EventColors do
  describe ".hex_for" do
    it "returns the mapped hex for a known id" do
      expect(described_class.hex_for("1")).to eq("#a4bdfc")
      expect(described_class.hex_for("11")).to eq("#dc2127")
    end

    it "accepts numeric input" do
      expect(described_class.hex_for(7)).to eq("#46d6db")
    end

    it "returns nil for unknown / blank ids" do
      expect(described_class.hex_for("99")).to be_nil
      expect(described_class.hex_for(nil)).to be_nil
      expect(described_class.hex_for("")).to be_nil
    end
  end
end
