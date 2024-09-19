RSpec.describe SearchBreaker do
  include ActiveJob::TestHelper

  subject { SearchBreaker.call(q, delims) }

  let(:delims) {
    {
      any: ["ANY", "ANY:"],
      not: "!",
      contains: ":",
      not_contains: "!:",
      not_exact: "!::",
      exact: "::",
      similar: "~",

      # any: "ANY",
      # not: "!",
      # contains: ":",
      # not_contains: "!:",
      # not_exact: "!::",
      # exact: "::",
      # similar: "~",
      # aliases: {
      #   "ANY:": "ANY",
      # }
    }
  }


  context "with different types of delimiters" do
    let(:q) {
      'name:thing has:"bigger string" search each ~sorta word !bad notes!:z name::thing ANY:(includes:dog includes:cat)'
    }
    let(:expected) {
      # First delim found breaks the rest of the non-whitespace as the value
      # <word><delim><word>? goes into "keys"
      # <delim><word> goes into "vals"
      # Parens get separated out and parsed as a new breaker
      {
        keys: {
          "name" => {
            contains: ["thing"],
            exact: ["thing"]
          },
          "has" => {
            contains: ["bigger string"],
          },
          "search" => {},
          "each" => {},
          "word" => {},
          "notes" => {
            not_contains: ["z"],
          }
        },
        vals: {
          similar: ["sorta"],
          not: ["bad"],
          any: [
            {
              keys: {
                "includes" => {
                  contains: ["dog", "cat"]
                }
              }
            }
          ]
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
          "tell" => { similar: ["/(?<direction>open|close|toggle)( (?:the|my))? garage/"] }
        }
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
          "event" => {
            contains: [
              { keys: { "name" => { contains: ["food"]} } },
              { vals: { any: [{ keys: { "name" => { exact: ["food", "drink"] } } }] } }
            ],
          },
          "travel" => {
            contains: [
              "arrived",
              "departed",
              { keys: { "arrived" => { exact: ["Delton"] } } }
            ]
          },
        }
      }
    }

    it "breaks into expected hash" do
      expect(subject).to eq(expected)
    end
  end

  context "when checking if a string matches the given data" do
    let(:q) { "event:data:custom:nested_key:fuzzy_val" }

    def matcher?(str, data)
      SearchBreakMatcher.new(str, data).match?
    end

    context "with a nested exact matcher" do
      let(:q) { "event:name::food" }

      it "returns correctly" do
        expect(matcher?(q, { event: { name: "foo" } })).to be(false)
        expect(matcher?(q, { event: { name: "food" } })).to be(true)
        expect(matcher?(q, { event: "food" })).to be(false)
      end
    end

    context "with an exact matcher of a nested value" do
      let(:q) { "event::workout" }

      it "returns correctly" do
        expect(matcher?(q, { event: { name: "hardworkout", notes: "Beat Saber" } })).to be(false)
        expect(matcher?(q, { event: { name: "workout", notes: "Beat Saber" } })).to be(true)
      end
    end

    context "with a matcher with an ANY value" do
      let(:q) { "event::workout" }

      it "returns correctly" do
        expect(matcher?("event:ANY(name:lazy notes:beat)", { event: { name: "hardworkout", notes: "Beat Saber" } })).to be(true)
        expect(matcher?("event:name:ANY(work thirst)", { event: { name: "hardworkout", notes: "Beat Saber" } })).to be(true)
        expect(matcher?("event:ANY(saber thirst)", { event: { name: "hardworkout", notes: "Beat Saber" } })).to be(true)
        expect(matcher?("event:name:ANY(flip thirst)", { event: { name: "hardworkout", notes: "Beat Saber" } })).to be(false)
        expect(matcher?("event:name:ANY(saber thirst)", { event: { name: "hardworkout", notes: "Beat Saber" } })).to be(false)
        expect(matcher?("event:name:ANY(food treat drink soda alcohol)", { event: { name: "Drink", notes: "Protein" } })).to be(true)
      end
    end

    context "with a single top level str" do
      let(:q) { "travel" }

      it "returns correctly" do
        expect(matcher?(q, { event: { name: "hardworkout", notes: "Beat Saber" } })).to be(false)
        expect(matcher?(q, { event: { name: "Life", notes: "Traveled to Rome" } })).to be(false)
        expect(matcher?(q, { travel: { action: "departed", location: "Home" } })).to be(true)
      end
    end

    context "with complex, nested data" do
      let(:data) {
        { event: { data: { custom: { nested_key: "fuzzy_val thing" } } } }
      }

      it "returns correctly" do
        expect(matcher?("event:data:custom:nested_key:fuzzy_val", data)).to be(true)
        expect(matcher?("event:data::nested_key:fuzzy_val", data)).to be(true)
        expect(matcher?("event:data:fuzzy_val", data)).to be(true)
        expect(matcher?("event:datam:fuzzy_val", data)).to be(false)
        expect(matcher?("event:ANY(data:fuzzy something)", data)).to be(true)
        expect(matcher?("event:ANY(data:nothing thing)", data)).to be(true)
        expect(matcher?("event:ANY(blah nothing)", data)).to be(false)
      end
    end
  end
end
