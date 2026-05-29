RSpec.describe Tokenizing::Breaker do
  describe ".call" do
    subject { Tokenizing::Breaker.call(q, delims) }

    let(:delims) {
      {
        any:          ["ANY", "ANY:"],
        not:          "!",
        contains:     ":",
        not_contains: "!:",
        not_exact:    "!::",
        exact:        "::",
        similar:      "~",
      }
    }

    context "with different types of delimiters" do
      let(:q) {
        'name:thing has:"bigger string" search each ~sorta word !bad notes!:z name::thing ANY:(includes:dog includes:cat)'
      }
      let(:expected) {
        {
          keys: {
            "name"   => {
              contains: ["thing"],
              exact:    ["thing"],
            },
            "has"    => {
              contains: ["bigger string"],
            },
            "search" => {},
            "each"   => {},
            "word"   => {},
            "notes"  => {
              not_contains: ["z"],
            },
          },
          vals: {
            similar: ["sorta"],
            not:     ["bad"],
            any:     [
              {
                keys: {
                  "includes" => {
                    contains: ["dog", "cat"],
                  },
                },
              },
            ],
          },
        }
      }

      it "breaks into a hash" do
        expect(subject).to eq(expected)
      end
    end

    context "with a non-delimeter string" do
      let(:q) { "hello" }
      let(:expected) {
        { keys: { "hello" => {} } }
      }

      it "sends back in the val" do
        expect(subject).to eq(expected)
      end
    end

    context "with nested and complex values" do
      let(:q) { "tell~/(?<direction>open|close|toggle)( (?:the|my))? garage/" }
      let(:expected) {
        {
          keys: {
            "tell" => { similar: ["/(?<direction>open|close|toggle)( (?:the|my))? garage/"] },
          },
        }
      }

      it "sends back in the val" do
        expect(subject).to eq(expected)
      end
    end

    context "with multi-level values" do
      let(:q) { "websocket:* websocket:garage event event:name:food event:ANY(name::food name::drink) travel:arrived travel:departed travel:arrived::Delton" }
      let(:expected) {
        {
          keys: {
            "websocket" => { contains: ["*", "garage"] },
            "event"     => {
              contains: [
                { keys: { "name" => { contains: ["food"] } } },
                { vals: { any: [{ keys: { "name" => { exact: ["food", "drink"] } } }] } },
              ],
            },
            "travel"    => {
              contains: [
                "arrived",
                "departed",
                { keys: { "arrived" => { exact: ["Delton"] } } },
              ],
            },
          },
        }
      }

      it "breaks into expected hash" do
        expect(subject).to eq(expected)
      end
    end
  end

  describe ".unwrap" do
    it "strips paired double quotes" do
      expect(Tokenizing::Breaker.unwrap('"foo bar"')).to eq("foo bar")
    end

    it "strips paired single quotes" do
      expect(Tokenizing::Breaker.unwrap("'foo bar'")).to eq("foo bar")
    end

    it "strips outer parens" do
      expect(Tokenizing::Breaker.unwrap("(food drink)")).to eq("food drink")
    end

    it "leaves unwrapped values alone" do
      expect(Tokenizing::Breaker.unwrap("food bar")).to eq("food bar")
    end
  end

  describe "DELIMITERS" do
    it "uses production semantics (`:!` for not_contains, `::!` for not_exact)" do
      expect(Tokenizing::Breaker::DELIMITERS[:not_contains]).to eq(":!")
      expect(Tokenizing::Breaker::DELIMITERS[:not_exact]).to eq("::!")
      expect(Tokenizing::Breaker::DELIMITERS[:any]).to include("ANY", "OR")
      expect(Tokenizing::Breaker::DELIMITERS[:regex]).to include("~", ":~")
    end
  end
end
