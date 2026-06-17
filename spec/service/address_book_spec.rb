require "rails_helper"

# Locks in the natural-language contact-name normalization used by
# Tesla.navigate, Jarvis voice, and any other caller that needs to resolve
# "Sarah", "Sarah's", "Sarah's house", "Sarahs" to the same Sarah contact.
RSpec.describe AddressBook do
  describe ".name_variants" do
    {
      "Sarah"           => %w[Sarah],
      "Sarah's"         => ["Sarah's", "Sarah"],
      "Sarah’s"         => ["Sarah’s", "Sarah"],            # curly apostrophe
      "Sarah's house"   => ["Sarah's house", "Sarah"],
      "Sarah's home"    => ["Sarah's home", "Sarah"],
      "Sarah's place"   => ["Sarah's place", "Sarah"],
      "Sarah’s house"   => ["Sarah’s house", "Sarah"],
      "Sarahs"          => %w[Sarahs Sarah],
    }.each do |input, expected|
      it "expands #{input.inspect} to #{expected.inspect}" do
        expect(described_class.name_variants(input)).to eq(expected)
      end
    end

    it "returns [] for blank input" do
      expect(described_class.name_variants("")).to eq([])
      expect(described_class.name_variants("   ")).to eq([])
    end
  end

  describe "#to_traveltime_param" do
    let(:book) { described_class.new(User.me) }

    it "resolves contact-name strings (Home, Sarah, etc.) to their street address" do
      home = double(primary_address: double(street: "123 Main St", present?: true))
      allow(book).to receive(:match_contact).with("Home").and_return(home)
      expect(book).not_to receive(:reverse_geocode)
      expect(book.to_traveltime_param("Home")).to eq("123 Main St")
    end

    it "passes raw address strings through stripped when no contact matches" do
      allow(book).to receive(:match_contact).and_return(nil)
      expect(book).not_to receive(:reverse_geocode)
      expect(book.to_traveltime_param("  1 Apple Park Way  ")).to eq("1 Apple Park Way")
    end

    it "joins coordinate arrays directly (no reverse_geocode)" do
      expect(book).not_to receive(:reverse_geocode)
      expect(book.to_traveltime_param([40.4804, -111.998])).to eq("40.4804,-111.998")
    end

    it "delegates non-string/non-coord input to to_address" do
      contact = double("Contact")
      expect(book).to receive(:to_address).with(contact).and_return("Resolved Address")
      expect(book.to_traveltime_param(contact)).to eq("Resolved Address")
    end

    it "returns nil for blank input" do
      expect(book.to_traveltime_param("   ")).to be_nil
    end
  end

  describe "#traveltime_seconds" do
    let(:book) { described_class.new(User.me) }

    it "returns 0 and skips the API call when origin == destination" do
      allow(Rails.env).to receive(:production?).and_return(true)
      expect(RestClient).not_to receive(:get)
      expect(book.traveltime_seconds("Home", "Home")).to eq(0)
    end
  end

  describe "#match_contact" do
    let(:book)  { described_class.new(User.me) }
    let(:sarah) { instance_double("Contact", present?: true) }

    before do
      # contact_by_name returns sarah only for the bare "Sarah".
      allow(book).to receive(:contact_by_name).and_return(nil)
      allow(book).to receive(:contact_by_name).with("Sarah").and_return(sarah)
    end

    it "returns the contact when the original string matches" do
      expect(book.match_contact("Sarah")).to eq(sarah)
    end

    it "tries normalized variants and returns the first hit" do
      expect(book.match_contact("Sarah's house")).to eq(sarah)
      expect(book.match_contact("Sarahs")).to eq(sarah)
    end

    it "returns nil when nothing matches any variant" do
      expect(book.match_contact("Unknown Person")).to be_nil
    end
  end
end
