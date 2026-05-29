RSpec.describe Tokenizing::Matcher do
  def matcher(str, data)
    described_class.new(str, data)
  end

  def matches?(str, data)
    matcher(str, data).match?
  end

  describe "#match?" do
    context "with a nested exact matcher (`::`)" do
      let(:q) { "event:name::food" }

      it "matches the exact nested value only" do
        expect(matches?(q, { event: { name: "foo" } })).to be(false)
        expect(matches?(q, { event: { name: "food" } })).to be(true)
        expect(matches?(q, { event: "food" })).to be(false)
      end
    end

    context "with a contains matcher (`:`)" do
      let(:q) { "event:workout" }

      it "matches substring" do
        expect(matches?(q, { event: { name: "hardworkout" } })).to be(true)
        expect(matches?(q, { event: { name: "yoga" } })).to be(false)
      end
    end

    context "with an exact matcher of a nested value (`::`)" do
      let(:q) { "event::workout" }

      it "matches only when the nested value equals exactly" do
        expect(matches?(q, { event: { name: "hardworkout", notes: "Beat Saber" } })).to be(false)
        expect(matches?(q, { event: { name: "workout", notes: "Beat Saber" } })).to be(true)
      end
    end

    context "with ANY(...)" do
      it "matches if any sub-value matches" do
        data = { event: { name: "hardworkout", notes: "Beat Saber" } }
        expect(matches?("event:ANY(name:lazy notes:beat)", data)).to be(true)
        expect(matches?("event:name:ANY(work thirst)", data)).to be(true)
        expect(matches?("event:ANY(saber thirst)", data)).to be(true)
        expect(matches?("event:name:ANY(flip thirst)", data)).to be(false)
      end

      it "matches case-insensitively" do
        data = { event: { name: "Drink", notes: "Protein" } }
        expect(matches?("event:name:ANY(food treat drink soda alcohol)", data)).to be(true)
      end
    end

    context "with a single top level string" do
      it "matches only the top-level scope" do
        expect(matches?("travel", { event: { name: "x" } })).to be(false)
        expect(matches?("travel", { travel: { action: "departed" } })).to be(true)
      end
    end

    context "with complex, nested data" do
      let(:data) {
        { event: { data: { custom: { nested_key: "fuzzy_val thing" } } } }
      }

      it "matches deeply nested colon paths" do
        expect(matches?("event:data:custom:nested_key:fuzzy_val", data)).to be(true)
        expect(matches?("event:data::nested_key:fuzzy_val", data)).to be(true)
        expect(matches?("event:data:fuzzy_val", data)).to be(true)
        expect(matches?("event:datam:fuzzy_val", data)).to be(false)
        expect(matches?("event:ANY(data:fuzzy something)", data)).to be(true)
        expect(matches?("event:ANY(blah nothing)", data)).to be(false)
      end
    end

    context "with hyphenated identifiers (NOT vs literal hyphen)" do
      let(:data) {
        { "hass-button": { button_id: "abc123", type: "button1_long_press" } }
      }

      it "treats interior hyphens as literal, not as negation" do
        expect(matches?("hass-button", data)).to be(true)
        expect(matches?("hass-button:type:long_press", data)).to be(true)
        expect(matches?("hass-button:type::button1_long_press", data)).to be(true)
        expect(matches?("hass-button:type::long_press", data)).to be(false)
      end
    end

    context "with quote-wrapped values" do
      it "matches single-quoted strings with spaces" do
        expect(matches?(%q(note:'has been'), { note: "this has been done" })).to be(true)
      end

      it "matches double-quoted strings with spaces" do
        expect(matches?(%q(note:"has been"), { note: "this has been done" })).to be(true)
      end

      it "matches quoted values with hyphens and digits" do
        expect(matches?(%q(amount::"-15.20"), { amount: "-15.20" })).to be(true)
      end
    end

    context "with regex (`~`, `:~`, `/.../`)" do
      it "matches a regex body via `:` + /.../ shorthand" do
        expect(matches?("tell:/(open|close)/", { tell: "open the door" })).to be(true)
        expect(matches?("tell:/(open|close)/", { tell: "lock the door" })).to be(false)
      end

      it "exposes match_list from `/.../` regex" do
        m = matcher("tell:/(open|close)/", { tell: "open the door" })
        expect(m.match?).to be(true)
        expect(m.match_data[:match_list]).to include("open")
      end

      it "exposes named_captures from `/.../` regex" do
        m = matcher('tell:/(?<amount>\d+)\s*mg/', { tell: "take 180 mg" })
        expect(m.match?).to be(true)
        expect(m.match_data[:named_captures][:amount]).to eq("180")
      end
    end
  end
end
