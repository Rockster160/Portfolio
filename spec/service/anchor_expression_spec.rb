require "rails_helper"

RSpec.describe AnchorExpression do
  describe ".parse" do
    it "reads a bare key as a zero offset" do
      expect(described_class.parse("sun:sunset")).to eq(
        { key: "sun:sunset", identifier: nil, offset_seconds: 0 },
      )
    end

    it "reads a negative offset as before the moment" do
      expect(described_class.parse("sun:sunset-5m")).to eq(
        { key: "sun:sunset", identifier: nil, offset_seconds: -300 },
      )
    end

    it "reads a positive offset as after it" do
      expect(described_class.parse("trash:pickup+30m")).to eq(
        { key: "trash:pickup", identifier: nil, offset_seconds: 1_800 },
      )
    end

    it "chains units" do
      expect(described_class.parse("sun:sunset-1h30m")[:offset_seconds]).to eq(-5_400)
    end

    it "handles each unit" do
      {
        "a:b-45s"   => -45,
        "a:b-2m"    => -120,
        "a:b-3h"    => -10_800,
        "a:b+1d"    => 86_400,
        "a:b-1w"    => -604_800,
        "a:b-3h30m" => -12_600,
        "a:b-1w2d"  => -777_600,
      }.each do |expression, seconds|
        expect(described_class.parse(expression)[:offset_seconds]).to eq(seconds)
      end
    end

    # Nothing in here knows which anchors exist - that's the user's data. Any
    # well-formed key parses, which is what makes a custom anchor possible
    # without touching code.
    it "accepts any key it has never heard of" do
      ["trash:pickup", "school:bell", "tide:high", "shift_2:start"].each do |key|
        expect(described_class.parse(key)).to eq(
          { key: key, identifier: nil, offset_seconds: 0 },
        )
      end
    end

    it "downcases the key" do
      expect(described_class.parse("SUN:Sunset-5M")[:key]).to eq("sun:sunset")
    end

    it "reads a bracketed identifier pinning one occurrence" do
      expect(described_class.parse("sun:sunset[2026-08-19]")).to eq(
        { key: "sun:sunset", identifier: "2026-08-19", offset_seconds: 0 },
      )
    end

    it "reads an offset after the identifier" do
      expect(described_class.parse("sun:sunset[2026-08-19]-5m")).to eq(
        { key: "sun:sunset", identifier: "2026-08-19", offset_seconds: -300 },
      )
    end

    it "handles a positive offset after an identifier" do
      expect(described_class.parse("trash:pickup[week-32]+1h30m")).to eq(
        { key: "trash:pickup", identifier: "week-32", offset_seconds: 5_400 },
      )
    end

    # The point of delimiting: the identifier ends where the bracket does, so
    # its contents never have to be guessed at.
    it "lets an identifier hold anything, even something shaped like an offset" do
      {
        "a:b[2026-08-19]"   => "2026-08-19",
        "a:b[-5m]"          => "-5m",
        "a:b[week 32]"      => "week 32",
        "a:b[Q3/2026]"      => "Q3/2026",
        "a:b[sun:sunset]"   => "sun:sunset",
        "a:b[trip_2026-08]" => "trip_2026-08",
      }.each do |expression, identifier|
        expect(described_class.parse(expression)&.dig(:identifier)).to eq(identifier),
          "expected #{expression.inspect} to pin #{identifier.inspect}"
      end
    end

    it "keeps an identifier that looks like an offset apart from a real one" do
      expect(described_class.parse("a:b[-5m]-1h")).to eq(
        { key: "a:b", identifier: "-5m", offset_seconds: -3_600 },
      )
    end

    it "refuses an unclosed bracket" do
      expect(described_class.parse("sun:sunset[2026-08-19")).to be_nil
      expect(described_class.parse("sun:sunset]")).to be_nil
      expect(described_class.parse("sun:sunset[]")).to be_nil
    end

    # The old colon form is gone - it has to stop parsing, not silently mean
    # something else.
    it "no longer accepts the colon-separated identifier" do
      expect(described_class.parse("sun:sunset:2026-08-19-5m")).to be_nil
    end

    it "refuses an offset with no unit" do
      expect(described_class.parse("sun:sunset-5")).to be_nil
    end

    it "refuses cron strings so CronParse can tell them apart" do
      ["0 6 * * *", "*/5 * * * *", "@daily", "", nil, "not a cron"].each do |str|
        expect(described_class.parse(str)).to be_nil
      end
    end
  end

  describe ".complaint" do
    it "explains a malformed offset" do
      expect(described_class.complaint("sun:sunset-5")).to include("offset", "sun:sunset-5m")
    end

    it "says nothing about a well-formed expression" do
      expect(described_class.complaint("sun:sunset-5m")).to be_nil
    end

    # It has no idea whether "sun:sunset" is real - only that it's shaped right.
    it "says nothing about an unknown but well-formed key" do
      expect(described_class.complaint("nonsense:thing")).to be_nil
    end

    it "says nothing about a cron" do
      expect(described_class.complaint("0 6 * * *")).to be_nil
    end
  end
end
