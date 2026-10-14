require "rails_helper"

RSpec.describe Buddy::Greeting do
  describe ".bare?" do
    it "matches a message that is only a hello" do
      aggregate_failures {
        [
          "hi",
          "Hey!",
          "hello there",
          "HELLO",
          "yo",
          "sup",
          "howdy",
          "morning",
          "good morning",
          "good evening",
          "what's up",
          "how are things?",
          "hey 👋",
          "hiya buddy",
          "hey, there",
        ].each { |text| expect(described_class.bare?(text)).to be(true), "expected #{text.inspect} to wave" }
      }
    end

    it "matches a message that is only a farewell" do
      aggregate_failures {
        [
          "bye",
          "Goodbye!",
          "night",
          "goodnight",
          "see you",
          "see ya later",
          "talk later",
          "ttyl",
          "take care",
          "bye bye",
          "cya",
        ].each { |text| expect(described_class.bare?(text)).to be(true), "expected #{text.inspect} to wave" }
      }
    end

    # A greeting glued to a request is a request — the whole point of "bare".
    it "does not match a greeting that carries an actual ask" do
      aggregate_failures {
        [
          "hi, add milk to the list",
          "hey can you set a timer",
          "morning - what's on today?",
          "good morning, remind me to call the vet",
          "yo turn the lights off",
          "hello is the garage shut?",
        ].each { |text| expect(described_class.bare?(text)).to be(false), "expected #{text.inspect} NOT to wave" }
      }
    end

    it "peels the pet's own name off the end, but not an arbitrary word" do
      expect(described_class.bare?("hey cobalt", name: "Cobalt")).to be(true)
      expect(described_class.bare?("hi gizmo", name: "Gizmo")).to be(true)
      expect(described_class.bare?("hi add", name: "Cobalt")).to be(false)
    end

    it "is false for empty or non-greeting text" do
      aggregate_failures {
        ["", "   ", "what's the weather", "thanks!", "ok"].each do |text|
          expect(described_class.bare?(text)).to be(false)
        end
      }
    end
  end
end
