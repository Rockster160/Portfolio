require "rails_helper"

RSpec.describe GoogleCalendar::HtmlText do
  describe ".to_plain" do
    it "strips tags and preserves visible text" do
      html = "<p>Hello <strong>world</strong></p>"
      expect(described_class.to_plain(html)).to eq("Hello world")
    end

    it "decodes HTML entities" do
      expect(described_class.to_plain("Meet &amp; Greet")).to eq("Meet & Greet")
    end

    it "returns nil for nil input (preserves Google's no-field semantics)" do
      expect(described_class.to_plain(nil)).to be_nil
    end

    it "returns nil when stripping leaves blank" do
      expect(described_class.to_plain("   ")).to be_nil
      expect(described_class.to_plain("<br><br>")).to be_nil
    end

    it "trims trailing whitespace on each line" do
      expect(described_class.to_plain("line  \nnext")).to eq("line\nnext")
    end
  end
end
