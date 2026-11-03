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
    }.then { |table|
      it "expands possessives, places and plurals back to the bare name" do
        table.each { |input, expected| expect(described_class.name_variants(input)).to eq(expected), input.inspect }
      end
    }

    it "returns [] for blank input" do
      expect(described_class.name_variants("")).to eq([])
      expect(described_class.name_variants("   ")).to eq([])
    end
  end

  describe "#address_in_phrase" do
    let(:user) { create(:user) }
    let(:book) { described_class.new(user) }

    def contact_with(name, addresses, nickname: nil)
      user.contacts.create!(name: name, nickname: nickname).tap { |contact|
        addresses.each { |label, street, primary|
          contact.addresses.create!(user: user, label: label, street: street, primary: primary)
        }
      }
    end

    before {
      contact_with("DMV", [["Herriman", "5278 W Anthem Peak Ln", true], ["Riverton", "12830 S Redwood Rd", false]])
      contact_with("Home", [[nil, "1 Home St", true]])
      contact_with("Home Depot", [[nil, "2 Depot Way", true]])
      contact_with("Momentum", [["Lehi", "3 Lehi Rd", true], ["Sandy", "4 Sandy Blvd", false]], nickname: "Climbing")
    }

    {
      "Herriman DMV"        => "5278 W Anthem Peak Ln",
      "the DMV in Riverton" => "12830 S Redwood Rd",
      "the DMV"             => "5278 W Anthem Peak Ln",
      "Momentum Sandy"      => "4 Sandy Blvd",
      "climbing in sandy"   => "4 Sandy Blvd",
      "the Home Depot"      => "2 Depot Way",
    }.then { |table|
      it "reads a contact plus a branch, nickname or article as that address" do
        table.each { |phrase, street| expect(book.address_in_phrase(phrase)&.street).to eq(street), phrase.inspect }
      end
    }

    it "leaves a bare name, a bare branch, an unknown branch, or a nearby-place phrase alone" do
      ["Trader Joe's near home", "DMV", "Herriman", "the DMV in Draper"].each do |phrase|
        expect(book.address_in_phrase(phrase)).to be_nil, phrase.inspect
      end
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

    # The 16h-drive bug: a bare venue name handed straight to Distance Matrix
    # geocodes globally. Anchor it to a plausible local point first.
    context "when a bare venue name geocodes implausibly far" do
      before {
        allow(book).to receive(:match_contact).and_return(nil)
        allow(book).to receive(:current_loc).and_return([40.51, -112.01])
      }

      it "falls back to a location-biased Places point and returns coords" do
        allow(book).to receive(:coords_for_location).with("The Neurodiversity Clinic")
          .and_return([-37.8796922, 145.0230786]) # Melbourne — the wrong continent
        allow(book).to receive(:nearest_from_name).with("The Neurodiversity Clinic", extract: :loc)
          .and_return([40.57, -111.86]) # the clinic down the road
        expect(book.to_traveltime_param("The Neurodiversity Clinic")).to eq("40.57,-111.86")
      end

      it "reports no drive rather than a wrong one when Places can't place it either" do
        allow(book).to receive(:coords_for_location).with("The Neurodiversity Clinic")
          .and_return([-37.8796922, 145.0230786])
        allow(book).to receive(:nearest_from_name).with("The Neurodiversity Clinic", extract: :loc)
          .and_return(nil)
        expect(book.to_traveltime_param("The Neurodiversity Clinic")).to be_nil
      end
    end
  end

  describe "#plausible_drive?" do
    let(:book) { described_class.new(User.me) }

    it "is true within the cap and false beyond it" do
      allow(book).to receive(:current_loc).and_return([40.51, -112.01])
      expect(book.plausible_drive?([40.57, -111.86])).to be(true)       # same valley
      expect(book.plausible_drive?([-37.8796922, 145.0230786])).to be(false) # Melbourne
    end

    it "has no opinion when there is no origin to measure against" do
      allow(book).to receive(:current_loc).and_return([])
      expect(book.plausible_drive?([-37.8796922, 145.0230786])).to be(true)
    end
  end

  describe "#traveltime_seconds" do
    let(:book) { described_class.new(User.me) }

    def stub_response(duration_in_traffic: nil, duration: nil)
      element = {}
      element[:duration_in_traffic] = { value: duration_in_traffic } if duration_in_traffic
      element[:duration] = { value: duration } if duration
      double(body: { rows: [{ elements: [element] }] }.to_json)
    end

    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(book).to receive(:to_traveltime_param) { |x| x }
      allow(book).to receive(:current_loc).and_return("origin")
    end

    it "returns 0 and skips the API call when origin == destination" do
      expect(RestClient).not_to receive(:get)
      expect(book.traveltime_seconds("Home", "Home")).to eq(0)
    end

    it "sends departure_time=now + traffic_model and reads duration_in_traffic" do
      captured_url = nil
      allow(RestClient).to receive(:get) { |url|
        captured_url = url
        stub_response(duration_in_traffic: 2700, duration: 2100)
      }

      expect(book.traveltime_seconds("dest", "origin")).to eq(2700)
      expect(captured_url).to include("traffic_model=best_guess")
      expect(captured_url).to include("departure_time=now")
      expect(captured_url).not_to include("arrival_time=")
    end

    it "passes a future arrival timestamp as departure_time" do
      future = 1.hour.from_now.to_i
      captured_url = nil
      allow(RestClient).to receive(:get) { |url|
        captured_url = url
        stub_response(duration_in_traffic: 1800)
      }

      book.traveltime_seconds("dest", "origin", at: future)
      expect(captured_url).to include("departure_time=#{future}")
    end

    it "falls back to plain duration when duration_in_traffic is missing" do
      allow(RestClient).to receive(:get).and_return(stub_response(duration: 1500))
      expect(book.traveltime_seconds("dest", "origin")).to eq(1500)
    end

    it "re-queries Google after the 10-minute cache bucket rolls over" do
      memory_store = ActiveSupport::Cache::MemoryStore.new
      allow(Rails).to receive(:cache).and_return(memory_store)

      allow(RestClient).to receive(:get).and_return(
        stub_response(duration_in_traffic: 1800),
        stub_response(duration_in_traffic: 2700),
      )

      # Anchored to the start of a bucket (epoch / 10 minutes). With a wall-clock
      # `t`, the +2 minute step could land in the NEXT bucket and re-fetch —
      # which is precisely what the middle assertion says must not happen — so
      # this passed or failed depending on the minute the suite ran.
      t = Time.utc(2026, 5, 14, 12, 0, 0)
      travel_to(t) do
        expect(book.traveltime_seconds("dest", "origin")).to eq(1800)
      end
      travel_to(t + 2.minutes) do
        # Same bucket — cache hit, no new fetch
        expect(book.traveltime_seconds("dest", "origin")).to eq(1800)
      end
      travel_to(t + 11.minutes) do
        # Next bucket — re-fetches and gets the fresher number
        expect(book.traveltime_seconds("dest", "origin")).to eq(2700)
      end

      expect(RestClient).to have_received(:get).twice
    end
  end

  describe "#nearest_from_name" do
    let(:book) { described_class.new(User.me) }

    before do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(book).to receive(:current_loc).and_return([40.5, -111.9])
    end

    it "returns nil and notifies Slack when the Places request raises" do
      allow(RestClient).to receive(:get).and_raise(RestClient::TooManyRequests.new)
      expect(::SlackNotifier).to receive(:err)

      expect {
        expect(book.nearest_from_name("Delton Lanes Riverton")).to be_nil
      }.not_to raise_error
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

  describe "#place_name" do
    let(:user)  { create(:user) }
    let(:book)  { described_class.new(user) }
    let(:here)  { [40.5, -111.9] }
    let(:agenda) { create(:agenda, user: user) }

    before do
      allow(book).to receive_messages(
        find_contact_near:     nil,
        nearest_establishment: nil,
        reverse_geocode:       "Riverton",
        geocode:               nil,
      )
    end

    def appointment(location, start_at: 30.minutes.from_now, at: here)
      allow(book).to receive(:geocode).with(location).and_return(at)
      create(:agenda_item, agenda: agenda, location: location, start_at: start_at)
    end

    it "names an appointment's place before anything else" do
      appointment("Horsetail Falls, Alpine, UT", at: [40.501, -111.901])
      allow(book).to receive(:find_contact_near).and_return(Contact.new(name: "Wil"))

      expect(book.place_name(here, establishments: true)).to eq("Horsetail Falls")
    end

    it "skips an appointment that is somewhere else" do
      appointment("Horsetail Falls, Alpine, UT", at: [40.6, -111.9])

      expect(book.place_name(here)).to eq("Riverton")
    end

    it "skips an appointment outside the window" do
      appointment("Horsetail Falls, Alpine, UT", start_at: 6.hours.from_now)

      expect(book.place_name(here)).to eq("Riverton")
    end

    it "leaves a bare street address to the business lookup" do
      appointment("12723 S Park Ave, Riverton, UT 84065")
      allow(book).to receive(:nearest_establishment).with(here).and_return({ name: "Riverton Dental", loc: here })

      expect(book.place_name(here, establishments: true)).to eq("Riverton Dental")
    end

    it "falls back to the nearest contact" do
      allow(book).to receive(:find_contact_near).with(here, any_args).and_return(Contact.new(name: "Home"))
      user.contacts.create!(name: "Home").addresses.create!(user: user, lat: here[0], lng: here[1])

      expect(book.place_name(here)).to eq("Home")
      expect(book.place_name(here, establishments: true)).to eq("Home")
    end

    describe "a saved place beside a business" do
      let(:unit) { [40.48870105646164, -112.01075832854691] }
      let(:pump) { [40.48894079132537, -112.01029965964834] }

      before {
        user.contacts.create!(name: "Storage").addresses.create!(user: user, lat: unit[0], lng: unit[1])
        allow(book).to receive(:nearest_establishment) { |at|
          book.near?(at, pump, 0.0003) ? { name: "Holiday Oil Gas", loc: pump } : { name: "Holiday Oil Car Wash", loc: [40.48868, -112.01090] }
        }
      }

      it "is the saved place when they're parked at it" do
        expect(book.place_name([40.488715, -112.010735], establishments: true)).to eq("Storage")
      end

      it "is the business when they're parked at the business" do
        expect(book.place_name([40.488925, -112.010320], establishments: true)).to eq("Holiday Oil Gas")
      end

      it "doesn't look for a business at all right on top of the saved place" do
        book.place_name(unit, establishments: true)

        expect(book).not_to have_received(:nearest_establishment)
      end
    end

    it "never asks about a business at Home" do
      user.contacts.create!(name: "Home").addresses.create!(user: user, lat: here[0], lng: here[1])

      expect(book.place_name([here[0] + 0.0008, here[1]], establishments: true)).to eq("Home")
      expect(book).not_to have_received(:nearest_establishment)
    end

    # The car parks down the street from the saved address, past `near?` but
    # well inside the business radius, and the nearest business is a stranger's.
    it "takes a saved place a stop is parked down the street from over a business" do
      book = described_class.new(user)
      allow(book).to receive_messages(nearest_establishment: nil, reverse_geocode: "Taylorsville")
      contact = user.contacts.create!(name: "Nathan")
      contact.addresses.create!(user: user, label: "Tavern", street: "5719 Easton St", lat: 40.6473989, lng: -111.9557654)
      parked = [40.648564, -111.9562]

      expect(book.place_name(parked, establishments: true)).to eq("Nathan")
      expect(book.place_name(parked)).to eq("Taylorsville")
    end

    it "falls back to the nearest business only when asked for one" do
      allow(book).to receive(:nearest_establishment).with(here).and_return({ name: "Costco", loc: here })

      expect(book.place_name(here, establishments: true)).to eq("Costco")
      expect(book.place_name(here)).to eq("Riverton")
    end

    it "falls back to the city" do
      expect(book.place_name(here, establishments: true)).to eq("Riverton")
    end
  end

  describe "#find_address_near" do
    let(:book) { described_class.new(User.me) }

    it "picks the nearest of two saved places in range" do
      far = instance_double(Address, loc: [40.5008, -111.9])
      close = instance_double(Address, loc: [40.5001, -111.9])
      allow(book).to receive(:addresses).and_return([far, close])

      expect(book.find_address_near([40.5, -111.9])).to eq(close)
    end

    # `User.me` and its address book outlive any one request.
    it "sees an address saved after the first lookup" do
      user = create(:user)
      book = described_class.new(user)
      expect(book.find_address_near([40.5, -111.9])).to be_nil

      contact = user.contacts.create!(name: "Nathan")
      address = contact.addresses.create!(user: user, label: "Tavern", street: "1 Main", lat: 40.5, lng: -111.9)

      expect(book.find_address_near([40.5, -111.9])).to eq(address)
    end
  end

  # Distances and review counts as Google returned them at real stops.
  describe "#pick_establishment" do
    let(:book) { described_class.new(create(:user)) }
    let(:stop) { [40.5, -111.9] }

    def place(name, metres, reviews)
      { name: name, user_ratings_total: reviews, geometry: { location: { lat: stop[0] + (metres / 111_000.0), lng: stop[1] } } }
    end

    def pick(*places) = book.pick_establishment(stop, places)&.dig(:name)

    it "takes the nearest" do
      expect(pick(place("CVS", 107, 165), place("Trader Joe's", 45, 26), place("Calle Tacos", 105, 45))).to eq("Trader Joe's")
    end

    it "takes the store over the clinic inside it" do
      expect(pick(place("Hobby Lobby", 96, 2681), place("Petco", 45, 1045), place("Vetco Vaccination Clinic", 42, 16)))
        .to eq("Petco")
    end

    it "takes the grocery store over the post office counter inside it" do
      expect(
        pick(place("Harmons Grocery", 30, 283), place("Harmons Pharmacy", 27, 41), place("United States Post Office", 20, 47)),
      ).to eq("Harmons Grocery")
    end

    it "keeps a busy neighbour that isn't busy enough to be the host" do
      expect(pick(place("LUXE Automotive", 25, 845), place("McDonald's", 25.5, 2835))).to eq("LUXE Automotive")
    end

    it "keeps the nearest when the busier place is further off" do
      expect(pick(place("Lee's Marketplace", 36, 408), place("K-COOK STATION", 133, 1006))).to eq("Lee's Marketplace")
    end

    it "gives back where the business is" do
      expect(book.pick_establishment(stop, [place("Petco", 45, 1045)])[:loc]).to eq([stop[0] + (45 / 111_000.0), stop[1]])
    end
  end

  describe "#stoppable_place?" do
    let(:book) { described_class.new(create(:user)) }

    def place(*types) = { geometry: { location: { lat: 40.5, lng: -111.9 } }, types: types }

    it "takes a business with a category" do
      expect(book.stoppable_place?(place("bar", "point_of_interest", "establishment"))).to be(true)
    end

    it "skips a listing with no category, which is usually someone's house" do
      expect(book.stoppable_place?(place("point_of_interest", "establishment"))).to be(false)
    end

    it "skips a trade that goes to the customer" do
      expect(book.stoppable_place?(place("roofing_contractor", "point_of_interest", "establishment"))).to be(false)
    end

    it "skips an answer about an area" do
      expect(book.stoppable_place?(place("neighborhood", "political"))).to be(false)
    end
  end
end
