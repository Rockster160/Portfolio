require "rails_helper"

RSpec.describe AddressBook do
  describe ".non_travelable?" do
    it "rejects URLs, video-conf hosts, placeholders, phone numbers and blanks" do
      [
        "https://example.com",
        "http://example.com/x",
        "www.example.com",
        "meet.google.com/abc-defg-hij",
        "zoom.us/j/123",
        "companyname.zoom.us/j/123",
        "teams.microsoft.com/l/meetup-join/...",
        "tbd",
        "Online",
        "virtual",
        "N/A",
        "+1 555-123-4567",
        "(555) 123-4567",
        "",
        "   ",
        nil,
      ].each { |location|
        expect(described_class.non_travelable?(location)).to be(true), location.inspect
      }
    end

    it "accepts real addresses + contact-name-like strings" do
      ["123 Main St", "Home", "Sarah's house", "Cherry Creek Mall, Denver CO"].each { |location|
        expect(described_class.non_travelable?(location)).to be(false), location
      }
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
