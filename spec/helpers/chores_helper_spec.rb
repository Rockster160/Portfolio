require "rails_helper"

RSpec.describe ChoresHelper, type: :helper do
  describe "#format_pebbles" do
    it "delimits thousands" do
      expect(helper.format_pebbles(1234)).to eq("1,234p")
      expect(helper.format_pebbles(1_000_000)).to eq("1,000,000p")
    end

    it "renders no leading sign for positive values by default" do
      expect(helper.format_pebbles(5)).to eq("5p")
    end

    it "renders an explicit sign when requested" do
      expect(helper.format_pebbles(5,  sign: :explicit)).to eq("+5p")
      expect(helper.format_pebbles(-5, sign: :explicit)).to eq("−5p")
      expect(helper.format_pebbles(0,  sign: :explicit)).to eq("0p")
    end

    it "uses a true minus glyph for negatives even without :explicit" do
      expect(helper.format_pebbles(-1234)).to eq("−1,234p")
    end

    it "treats `p` as a fixed unit — never pluralizes" do
      expect(helper.format_pebbles(1)).to eq("1p")
      expect(helper.format_pebbles(2)).to eq("2p")
    end
  end

  describe "#format_count" do
    it "delimits thousands without any suffix" do
      expect(helper.format_count(1234)).to eq("1,234")
      expect(helper.format_count(0)).to eq("0")
      expect(helper.format_count(99)).to eq("99")
    end
  end

  describe "#format_multiplier" do
    it "drops trailing .0 on whole-number multipliers" do
      expect(helper.format_multiplier(2.0)).to eq("2")
      expect(helper.format_multiplier(1.5)).to eq("1.5")
    end
  end
end
