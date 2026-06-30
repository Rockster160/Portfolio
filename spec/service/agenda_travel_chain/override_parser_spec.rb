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
      expect(p.parse("Before:Costco")[:before]).to eq([{ location: "Costco", dwell_seconds: 0 }])
    end

    it "parses before: and after: as comma-separated waypoint hashes" do
      notes = <<~NOTES
        Errand run before main meeting
        before:Costco,Harmons
        after:Lowe's,In N Out,Doug's,Home
      NOTES
      result = p.parse(notes)
      expect(result[:before]).to eq([
        { location: "Costco",  dwell_seconds: 0 },
        { location: "Harmons", dwell_seconds: 0 },
      ])
      expect(result[:after]).to eq([
        { location: "Lowe's",   dwell_seconds: 0 },
        { location: "In N Out", dwell_seconds: 0 },
        { location: "Doug's",   dwell_seconds: 0 },
        { location: "Home",     dwell_seconds: 0 },
      ])
    end

    it "honors quoted commas inside list entries" do
      notes = 'after:"123 Main St, Apt 4",Doug'
      expect(p.parse(notes)[:after]).to eq([
        { location: "123 Main St, Apt 4", dwell_seconds: 0 },
        { location: "Doug",               dwell_seconds: 0 },
      ])
    end

    it "tolerates whitespace around items" do
      expect(p.parse("before:  Costco , Harmons  ")[:before]).to eq([
        { location: "Costco",  dwell_seconds: 0 },
        { location: "Harmons", dwell_seconds: 0 },
      ])
    end

    describe "dwell durations on waypoints" do
      it "parses trailing `Nm` as dwell minutes" do
        expect(p.parse("before:Costco 15m")[:before]).to eq([
          { location: "Costco", dwell_seconds: 900 },
        ])
      end

      it "parses trailing `Nh` as dwell hours" do
        expect(p.parse("before:Office 2h")[:before]).to eq([
          { location: "Office", dwell_seconds: 7200 },
        ])
      end

      it "parses combined `NhMm` (with or without spaces)" do
        expect(p.parse("before:Office 1h30m")[:before]).to eq([
          { location: "Office", dwell_seconds: 5400 },
        ])
        expect(p.parse("before:Office 1h 30m")[:before]).to eq([
          { location: "Office", dwell_seconds: 5400 },
        ])
      end

      it "accepts longer unit forms (min, hrs, hour, hours)" do
        expect(p.parse("before:Costco 45min")[:before]).to eq([
          { location: "Costco", dwell_seconds: 2700 },
        ])
        expect(p.parse("before:Office 2hrs")[:before]).to eq([
          { location: "Office", dwell_seconds: 7200 },
        ])
        expect(p.parse("before:Office 1hour")[:before]).to eq([
          { location: "Office", dwell_seconds: 3600 },
        ])
      end

      it "handles a mix of waypoints with and without dwells" do
        result = p.parse("before:Harmon's 10m, Costco 15m, Lowes")
        expect(result[:before]).to eq([
          { location: "Harmon's", dwell_seconds: 600 },
          { location: "Costco",   dwell_seconds: 900 },
          { location: "Lowes",    dwell_seconds: 0 },
        ])
      end

      it "applies dwell parsing to after: as well" do
        expect(p.parse("after:Bar 30m, Home")[:after]).to eq([
          { location: "Bar",  dwell_seconds: 1800 },
          { location: "Home", dwell_seconds: 0 },
        ])
      end

      it "does not split locations whose names just happen to end in a digit" do
        # No trailing unit suffix → entire entry is location
        expect(p.parse("before:Building 4, Suite 200")[:before]).to eq([
          { location: "Building 4", dwell_seconds: 0 },
          { location: "Suite 200",  dwell_seconds: 0 },
        ])
      end

      it "preserves quoted addresses with internal numbers" do
        result = p.parse('before:"123 Main St, Apt 4" 10m')
        expect(result[:before]).to eq([
          { location: "123 Main St, Apt 4", dwell_seconds: 600 },
        ])
      end
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

    it "is true when only a dwell duration changes" do
      expect(p.changed?("before:Costco 10m", "before:Costco 20m")).to be(true)
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
