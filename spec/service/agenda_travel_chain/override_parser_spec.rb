require "rails_helper"

RSpec.describe AgendaTravelChain::OverrideParser do
  let(:p) { described_class }

  describe ".parse" do
    it "returns the empty shape for nil/blank notes" do
      expect(p.parse(nil)).to eq(p::EMPTY)
      expect(p.parse("")).to eq(p::EMPTY)
      expect(p.parse("   \n  ")).to eq(p::EMPTY)
    end

    it "matches each token only at the start of a line" do
      notes = "We're going to nonav today\n actually nonav"
      # First match is inline, second has leading whitespace — neither qualifies
      # for the start-of-line rule, so nonav stays false.
      expect(p.parse(notes)[:nonav]).to be(false)

      anchored = "nonav\nsome other prose"
      expect(p.parse(anchored)[:nonav]).to be(true)
    end

    it "is case-insensitive" do
      expect(p.parse("NoNaV")[:nonav]).to be(true)
      expect(p.parse("NOTME")[:notme]).to be(true)
      expect(p.parse("Before:Costco")[:before]).to eq(["Costco"])
    end

    it "parses before: and after: as comma-separated lists" do
      notes = <<~NOTES
        Errand run before main meeting
        before:Costco,Harmons
        after:Lowe's,In N Out,Doug's,Home
      NOTES
      result = p.parse(notes)
      expect(result[:before]).to eq(["Costco", "Harmons"])
      expect(result[:after]).to eq(["Lowe's", "In N Out", "Doug's", "Home"])
    end

    it "honors quoted commas inside list entries" do
      notes = 'after:"123 Main St, Apt 4",Doug'
      expect(p.parse(notes)[:after]).to eq(["123 Main St, Apt 4", "Doug"])
    end

    it "tolerates whitespace around items" do
      expect(p.parse("before:  Costco , Harmons  ")[:before]).to eq(["Costco", "Harmons"])
    end

    it "returns frozen empty arrays when a token is missing" do
      result = p.parse("nonav")
      expect(result[:before]).to eq([])
      expect(result[:before]).to be_frozen
      expect(result[:after]).to be_frozen
    end

    it "ignores tokens that aren't at line start" do
      notes = "thinking nonav is fun.\n  before:nothing"
      result = p.parse(notes)
      expect(result[:nonav]).to be(false)
      expect(result[:before]).to eq([])
    end

    it "parses from: and to: as single string values" do
      notes = <<~NOTES
        Pickup detour
        from:123 Main St, Springfield
        to:Side entrance
      NOTES
      result = p.parse(notes)
      expect(result[:from]).to eq("123 Main St, Springfield")
      expect(result[:to]).to eq("Side entrance")
    end

    it "honors surrounding quotes on from:/to: values" do
      notes = 'from:"123 Main St, Apt 4"'
      expect(p.parse(notes)[:from]).to eq("123 Main St, Apt 4")
    end

    it "leaves from:/to: nil when absent" do
      expect(p.parse("nonav")[:from]).to be_nil
      expect(p.parse("nonav")[:to]).to be_nil
    end

    it "is case-insensitive for from:/to:" do
      expect(p.parse("FROM:Costco")[:from]).to eq("Costco")
      expect(p.parse("To:Home")[:to]).to eq("Home")
    end

    it "only matches from:/to: at line start" do
      notes = "I'll drive from:somewhere fun"
      expect(p.parse(notes)[:from]).to be_nil
    end
  end

  describe ".changed?" do
    it "is false when prose differs but parsed overrides match" do
      a = "Notes about the meeting\nbefore:Costco"
      b = "Different prose\nbefore:Costco"
      expect(p.changed?(a, b)).to be(false)
    end

    it "is true when an override list changes" do
      expect(p.changed?("before:A", "before:A,B")).to be(true)
    end

    it "is true when a flag toggles" do
      expect(p.changed?("", "nonav")).to be(true)
    end

    it "is true when from:/to: change" do
      expect(p.changed?("from:Home", "from:Office")).to be(true)
      expect(p.changed?("", "to:Side entrance")).to be(true)
    end
  end
end
