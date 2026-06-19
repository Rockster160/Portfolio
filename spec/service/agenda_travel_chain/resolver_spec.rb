require "rails_helper"

RSpec.describe AgendaTravelChain::Resolver do
  let(:user) { User.me }
  let(:address_book) { instance_double("AddressBook") }
  let(:resolver) { described_class.new(user) }

  before { allow(user).to receive(:address_book).and_return(address_book) }

  describe "#resolve_location" do
    it "returns nil for blank input without touching the address book" do
      expect(address_book).not_to receive(:geocode)
      expect(resolver.resolve_location("")).to be_nil
      expect(resolver.resolve_location(nil)).to be_nil
    end

    it "returns nil for non-travelable terms (NON_TRAVELABLE list)" do
      allow(::AddressBook).to receive(:non_travelable?).with("zoom").and_return(true)
      expect(address_book).not_to receive(:geocode)
      expect(resolver.resolve_location("zoom")).to be_nil
    end

    it "prioritizes a contact match over direct geocoding (Sarah's House)" do
      allow(::AddressBook).to receive(:non_travelable?).and_return(false)
      contact = double(primary_address: double(street: "123 Main St"))
      allow(address_book).to receive(:match_contact).with("Sarah's House").and_return(contact)
      allow(address_book).to receive(:geocode).with("123 Main St").and_return([40.6, -111.8])
      expect(address_book).not_to receive(:geocode).with("Sarah's House")
      expect(address_book).not_to receive(:nearest_from_name)

      expect(resolver.resolve_location("Sarah's House")).to eq(
        address: "123 Main St", lat: 40.6, lng: -111.8,
      )
    end

    it "falls through past a matched contact whose address won't geocode" do
      allow(::AddressBook).to receive(:non_travelable?).and_return(false)
      contact = double(primary_address: double(street: "Apt B"))
      allow(address_book).to receive(:match_contact).with("Bob").and_return(contact)
      allow(address_book).to receive(:geocode).with("Apt B").and_return(nil)
      allow(address_book).to receive(:geocode).with("Bob").and_return(nil)
      allow(address_book).to receive(:nearest_from_name).with("Bob", extract: :address)
        .and_return("Bob's Burgers, 100 Foo St")
      allow(address_book).to receive(:nearest_from_name).with("Bob", extract: :loc)
        .and_return([40.7, -111.7])

      expect(resolver.resolve_location("Bob")).to eq(
        address: "Bob's Burgers, 100 Foo St", lat: 40.7, lng: -111.7,
      )
    end

    it "uses geocoded coords directly when geocoding succeeds (full address)" do
      allow(::AddressBook).to receive(:non_travelable?).and_return(false)
      allow(address_book).to receive(:match_contact).with("4512 W Bartlett Dr").and_return(nil)
      allow(address_book).to receive(:geocode).with("4512 W Bartlett Dr").and_return([40.5, -111.99])
      expect(address_book).not_to receive(:nearest_from_name)

      expect(resolver.resolve_location("4512 W Bartlett Dr")).to eq(
        address: "4512 W Bartlett Dr", lat: 40.5, lng: -111.99,
      )
    end

    it "falls back to nearest_from_name when geocode misses (casual chain name)" do
      allow(::AddressBook).to receive(:non_travelable?).and_return(false)
      allow(address_book).to receive(:match_contact).with("Costco").and_return(nil)
      allow(address_book).to receive(:geocode).with("Costco").and_return(nil)
      allow(address_book).to receive(:nearest_from_name).with("Costco", extract: :address)
        .and_return("13123 S 5600 W, Herriman, UT 84096")
      allow(address_book).to receive(:nearest_from_name).with("Costco", extract: :loc)
        .and_return([40.51, -112.01])

      expect(resolver.resolve_location("Costco")).to eq(
        address: "13123 S 5600 W, Herriman, UT 84096", lat: 40.51, lng: -112.01,
      )
    end

    it "returns nil when contact, geocode, and Places all miss" do
      allow(::AddressBook).to receive(:non_travelable?).and_return(false)
      allow(address_book).to receive(:match_contact).with("Some Made Up Place").and_return(nil)
      allow(address_book).to receive(:geocode).with("Some Made Up Place").and_return(nil)
      allow(address_book).to receive(:nearest_from_name).with("Some Made Up Place", extract: :address)
        .and_return(nil)

      expect(address_book).not_to receive(:nearest_from_name).with(anything, extract: :loc)
      expect(resolver.resolve_location("Some Made Up Place")).to be_nil
    end
  end
end
