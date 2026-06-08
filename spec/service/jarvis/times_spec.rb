require "rails_helper"

RSpec.describe Jarvis::Times do
  describe ".extract_time" do
    it "matches a bare day word" do
      pre_text, parsed = described_class.extract_time("remind me evening")
      expect(pre_text).to eq("evening")
      expect(parsed).to be_present
    end

    it "does not match a day word embedded in a hyphenated identifier" do
      pre_text, parsed = described_class.extract_time("set evening-mode")
      expect(pre_text).to be_nil
      expect(parsed).to be_nil
    end

    it "does not match a day word followed by a hyphen-word suffix" do
      pre_text, parsed = described_class.extract_time("activate monday-routine")
      expect(pre_text).to be_nil
      expect(parsed).to be_nil
    end

    it "does not match a month word embedded in a hyphenated identifier" do
      pre_text, parsed = described_class.extract_time("trigger march-update")
      expect(pre_text).to be_nil
      expect(parsed).to be_nil
    end
  end
end
