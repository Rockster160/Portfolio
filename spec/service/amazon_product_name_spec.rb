require "rails_helper"

# Real titles from the order history. They are written for search, not reading:
# 139 characters at the median, 273 at the worst.
RSpec.describe AmazonProductName do
  describe ".tidy" do
    it "keeps the name and drops the feature list" do
      expect(described_class.tidy(
               "Achiou Winter Gloves for Men Women, Touch Screen Texting Warm Gloves",
             )).to eq("Achiou Winter Gloves")
    end

    it "drops a bracketed aside and a pack count in front of the name" do
      expect(described_class.tidy("(50 Pads) Sticky Notes 1.5x2, Vintage Colors")).to(
        eq("Sticky Notes 1.5x2"),
      )
      expect(described_class.tidy("160 Pcs 8 Colors Blank Dice")).to eq("8 Colors Blank Dice")
      expect(described_class.tidy("Pack of 3 Microfiber Towels")).to eq("Microfiber Towels")
    end

    # Two passes: the count is only visible once the bracket is gone.
    it "strips both when a title opens with a bracket and a count" do
      expect(described_class.tidy("(2 Pack) 60 Pcs Metal Bulldog Clips")).to(
        eq("Metal Bulldog Clips"),
      )
    end

    # Splitting on "with" left this stranded as "Moko Charging Stand Compatible".
    it "does not leave a dangling qualifier behind" do
      expect(described_class.tidy("Moko Charging Stand Compatible with iPhone 15")).to(
        eq("Moko Charging Stand"),
      )
    end

    # "Power Strip" is 11 characters and a perfectly good name; an earlier
    # length guard reverted it to the full 90-character title.
    it "keeps a short two-word name rather than reverting to the whole title" do
      expect(described_class.tidy("Power Strip with USB, Flat Plug Extension Cord Surge")).to(
        eq("Power Strip"),
      )
    end

    # A stub IS worse than a long title: "Ajmal" alone says nothing.
    it "falls back to the full title when the head is a single word" do
      expect(described_class.tidy("Ajmal, L'Eau Blu EDP For Men")).to(
        start_with("Ajmal, L'Eau Blu"),
      )
    end

    it "truncates at a word boundary, never mid-word" do
      long = "Captiva Designs 4-Burner Propane Gas BBQ Grill Stainless Steel Outdoor Cooking"
      result = described_class.tidy(long)

      expect(result.length).to be <= described_class::MAX + 1
      expect(result).to end_with("…")
      expect(result.delete("…")).to eq(result.delete("…").rstrip)
    end

    # The brand is the most identifying part, and "Rubbermaid" cannot be told
    # from "Hansleep" by shape.
    it "never strips the brand" do
      expect(described_class.tidy("Rubbermaid Commercial Products Food Service Tote")).to(
        start_with("Rubbermaid"),
      )
      expect(described_class.tidy("Hansleep Fleece Brown King Blanket")).to(
        start_with("Hansleep"),
      )
    end

    it "says nothing about nothing" do
      expect(described_class.tidy(nil)).to eq("")
      expect(described_class.tidy("")).to eq("")
    end
  end

  describe ".summarize" do
    it "names the item when a shipment held one" do
      expect(described_class.summarize(["Humane Mouse Trap"])).to eq("Humane Mouse Trap")
    end

    it "counts the rest when it held several" do
      expect(described_class.summarize(["Humane Mouse Trap", "Power Strip", "Sticky Notes"])).to(
        eq("Humane Mouse Trap + 2 more"),
      )
    end

    it "is nil when there is nothing to name" do
      expect(described_class.summarize([])).to be_nil
      expect(described_class.summarize([""])).to be_nil
    end
  end
end
