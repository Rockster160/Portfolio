require "rails_helper"

RSpec.describe AddressBook do
  describe ".non_travelable?" do
    it "rejects http(s) and www URLs" do
      expect(described_class.non_travelable?("https://example.com")).to be true
      expect(described_class.non_travelable?("http://example.com/x")).to be true
      expect(described_class.non_travelable?("www.example.com")).to be true
    end

    it "rejects common video-conf hosts even without scheme" do
      expect(described_class.non_travelable?("meet.google.com/abc-defg-hij")).to be true
      expect(described_class.non_travelable?("zoom.us/j/123")).to be true
      expect(described_class.non_travelable?("companyname.zoom.us/j/123")).to be true
      expect(described_class.non_travelable?("teams.microsoft.com/l/meetup-join/...")).to be true
    end

    it "rejects placeholder text" do
      expect(described_class.non_travelable?("tbd")).to be true
      expect(described_class.non_travelable?("Online")).to be true
      expect(described_class.non_travelable?("virtual")).to be true
      expect(described_class.non_travelable?("N/A")).to be true
    end

    it "rejects phone-like digit strings" do
      expect(described_class.non_travelable?("+1 555-123-4567")).to be true
      expect(described_class.non_travelable?("(555) 123-4567")).to be true
    end

    it "accepts real addresses + contact-name-like strings" do
      expect(described_class.non_travelable?("123 Main St")).to be false
      expect(described_class.non_travelable?("Home")).to be false
      expect(described_class.non_travelable?("Sarah's house")).to be false
      expect(described_class.non_travelable?("Cherry Creek Mall, Denver CO")).to be false
    end

    it "treats blank as non-travelable" do
      expect(described_class.non_travelable?("")).to be true
      expect(described_class.non_travelable?("   ")).to be true
      expect(described_class.non_travelable?(nil)).to be true
    end
  end

  describe "#to_traveltime_param" do
    let(:user) { create(:user) }
    let(:address_book) { described_class.new(user) }

    it "returns nil for URLs without hitting any lookup" do
      expect(address_book).not_to receive(:match_contact)
      expect(address_book.to_traveltime_param("https://meet.google.com/abc")).to be_nil
    end

    it "still resolves contact-name strings through to_address" do
      expect(address_book.to_traveltime_param("Definitely Not A Contact Name 1234 Address")).to eq("Definitely Not A Contact Name 1234 Address")
    end
  end
end
