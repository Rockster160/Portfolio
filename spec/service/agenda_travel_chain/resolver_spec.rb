require "rails_helper"

RSpec.describe AgendaTravelChain::Resolver do
  let(:user) { User.me }
  let(:address_book) { instance_double("AddressBook") }
  let(:resolver) { described_class.new(user) }

  before {
    allow(user).to receive(:address_book).and_return(address_book)
    # Home, for the distance sanity check. Every existing case resolves to
    # somewhere in the valley, so the bound never bites on them.
    allow(address_book).to receive(:current_loc).and_return([40.51, -112.01])
  }

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

    # Prod agenda_item 1054, 3 Sep. Chelsea's "Therapy" at 2 PM, location
    # "Neurodiversity Clinic" — a venue name with no city — geocoded to
    # -37.879, 145.023. That is Melbourne, Australia. `travel_minutes` and
    # `travel_seconds` came back empty because there is no driving route across
    # the Pacific, so `agenda-travel-prepare` and `agenda-travel-go` were never
    # created at all and she got no leave-by and no time-to-go. The only visible
    # symptom was a briefing that named the appointment with nothing attached.
    describe "a geocode that lands on the wrong continent" do
      before {
        allow(::AddressBook).to receive(:non_travelable?).and_return(false)
        allow(address_book).to receive(:match_contact).and_return(nil)
        allow(address_book).to receive(:geocode).with("Neurodiversity Clinic")
          .and_return([-37.8796922, 145.0230786])
      }

      it "throws it away and asks Places, which knows where they are" do
        allow(address_book).to receive(:nearest_from_name).with("Neurodiversity Clinic", extract: :address)
          .and_return("123 Clinic Way, Sandy, UT")
        allow(address_book).to receive(:nearest_from_name).with("Neurodiversity Clinic", extract: :loc)
          .and_return([40.57, -111.86])

        expect(resolver.resolve_location("Neurodiversity Clinic")).to eq(
          address: "123 Clinic Way, Sandy, UT", lat: 40.57, lng: -111.86,
        )
      end

      # Missing beats wrong. A nil here leaves the item without a drive, which
      # is honest; the Melbourne coords leave it with a drive that silently
      # produces nothing.
      it "gives back nothing at all when Places can't place it either" do
        allow(address_book).to receive(:nearest_from_name).with("Neurodiversity Clinic", extract: :address)
          .and_return(nil)

        expect(resolver.resolve_location("Neurodiversity Clinic")).to be_nil
      end

      # The bound is on the far side of any drive anyone takes, not on the near
      # side of a rare one. Cross-state is a real trip and has to survive.
      it "keeps a long but real drive" do
        allow(address_book).to receive(:geocode).with("Delton Lanes, Las Vegas")
          .and_return([36.1699, -115.1398])
        expect(address_book).not_to receive(:nearest_from_name)

        expect(resolver.resolve_location("Delton Lanes, Las Vegas")).to eq(
          address: "Delton Lanes, Las Vegas", lat: 36.1699, lng: -115.1398,
        )
      end

      # Measured from where they ARE. On a trip, the venue down the road from
      # the hotel is the plausible one and home is the outlier.
      it "measures from their current location, not from home" do
        allow(address_book).to receive(:current_loc).and_return([-37.88, 145.02])
        expect(address_book).not_to receive(:nearest_from_name)

        expect(resolver.resolve_location("Neurodiversity Clinic")).to eq(
          address: "Neurodiversity Clinic", lat: -37.8796922, lng: 145.0230786,
        )
      end

      # An install with nothing to measure against gets the old behavior rather
      # than a blanket refusal.
      it "disbelieves nothing when it has no idea where they are" do
        allow(address_book).to receive(:current_loc).and_return([])
        expect(address_book).not_to receive(:nearest_from_name)

        expect(resolver.resolve_location("Neurodiversity Clinic")[:lat]).to eq(-37.8796922)
      end
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
