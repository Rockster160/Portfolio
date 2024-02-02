RSpec.describe SearchBreaker do
  include ActiveJob::TestHelper

  subject { SearchBreaker.call(q, delims) }


  let(:delims) {
    {
      or: "OR",
      not: "!",
      contains: ":",
      not_contains: "!:",
      not_exact: "!::",
      exact: "::",
      similar: "~",
      aliases: {
        "OR:": "OR",
      }
    }
  }


  context "with different types of delimiters" do
    let(:q) {
      'name:thing has:"bigger string" search each ~sorta word !bad notes!:z name::thing OR:(includes:dog includes:cat)'
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
          or: [
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

  context "with multi-level values" do
    let(:q) { "websocket:* websocket:garage event event:name:food event:OR(name::food name::drink) travel:arrived travel:departed travel:arrived::Delton" }
    let(:expected) {
      {
        keys: {
          "websocket" => { contains: ["*", "garage"] },
          "event" => {
            contains: [
              { keys: { "name" => { contains: ["food"]} } },
              { vals: { or: [{ keys: { "name" => { exact: ["food", "drink"] } } }] } }
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
end
