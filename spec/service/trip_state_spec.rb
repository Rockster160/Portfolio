require "rails_helper"

# Trip lifecycle + leg navigation. Most of the surface is read/write
# against UserCache; the geofence cross-check stubs AddressBook +
# LocationCache so the spec doesn't depend on Google.
RSpec.describe TripState do
  let(:user) { create(:user) }
  let(:agenda) { create(:agenda, user: user) }
  let(:item) {
    agenda.agenda_items.create!(
      kind: :event, name: "TMS",
      start_at: 1.day.from_now, end_at: 1.day.from_now + 30.minutes,
      location: "Office",
      metadata: {
        "travel" => {
          "travel_minutes" => 25,
          "before_legs" => [
            { "from" => "Home", "to" => "Costco",   "drive_seconds" => 600, "dwell_seconds" => 600 },
            { "from" => "Costco", "to" => "Harmons", "drive_seconds" => 600, "dwell_seconds" => 300 },
            { "from" => "Harmons", "to" => "Office", "drive_seconds" => 600, "dwell_seconds" => 0   },
          ],
        },
      },
    )
  }

  before do
    allow(::AgendaTravelChainSyncWorker).to receive(:perform_async).and_return(nil)
    allow(::Jil).to receive(:trigger)
  end

  describe "lifecycle" do
    it "starts at leg_index 0 and fires :trip-started" do
      state = described_class.start!(item, user)
      expect(state).to include(agenda_item_id: item.id, leg_index: 0)
      expect(::Jil).to have_received(:trigger).with(
        user, :"trip-started", hash_including(agenda_item_id: item.id, leg_index: 0, next_stop: "Costco"), auth: :trigger,
      )
      expect(described_class.active?(user)).to be(true)
    end

    it "advance! bumps the leg index and fires :trip-advanced with the new next_stop" do
      described_class.start!(item, user)
      described_class.advance!(user)
      expect(described_class.current(user)[:leg_index]).to eq(1)
      expect(::Jil).to have_received(:trigger).with(
        user, :"trip-advanced", hash_including(leg_index: 1, next_stop: "Harmons"), auth: :trigger,
      )
    end

    it "finish! clears state and fires :trip-ended" do
      described_class.start!(item, user)
      described_class.finish!(user)
      expect(described_class.active?(user)).to be(false)
      expect(::Jil).to have_received(:trigger).with(user, :"trip-ended", hash_including(agenda_item_id: item.id), auth: :trigger)
    end

    it "advance! is a no-op (returns nil, no trigger) when there's no active trip" do
      expect(described_class.advance!(user)).to be_nil
      expect(::Jil).not_to have_received(:trigger).with(anything, /trip-/, anything, anything)
    end

    it "finish! is silent when no trip is active" do
      described_class.finish!(user)
      expect(::Jil).not_to have_received(:trigger).with(anything, /trip-/, anything, anything)
    end
  end

  describe "stop lookup" do
    before { described_class.start!(item, user) }

    it "current_stop returns the leg at the current index" do
      expect(described_class.current_stop(user)).to eq("Costco")
      described_class.advance!(user)
      expect(described_class.current_stop(user)).to eq("Harmons")
      described_class.advance!(user)
      expect(described_class.current_stop(user)).to eq("Office")
    end

    it "next_stop returns one ahead of current" do
      expect(described_class.next_stop(user)).to eq("Harmons")
      described_class.advance!(user)
      expect(described_class.next_stop(user)).to eq("Office")
    end

    it "returns nil once the index walks off the end" do
      3.times { described_class.advance!(user) }
      expect(described_class.current_stop(user)).to be_nil
      expect(described_class.next_stop(user)).to be_nil
    end

    it "returns nil if the source AgendaItem has been deleted mid-trip" do
      item.destroy
      expect(described_class.current_stop(user)).to be_nil
    end
  end

  describe ".start_for_destination!" do
    let!(:future_event) {
      agenda.agenda_items.create!(
        kind: :event, name: "Match",
        start_at: 2.hours.from_now, end_at: 2.hours.from_now + 30.minutes,
        location: "Office",
        metadata: {
          "travel" => {
            "before_legs" => [
              { "from" => "Home", "to" => "Costco", "drive_seconds" => 600, "dwell_seconds" => 0 },
              { "from" => "Costco", "to" => "Office", "drive_seconds" => 600, "dwell_seconds" => 0 },
            ],
          },
        },
      )
    }

    it "starts a trip when destination matches an upcoming first leg (case-insensitive)" do
      expect(described_class.start_for_destination!("COSTCO", user)).to be_present
      expect(described_class.current(user)[:agenda_item_id]).to eq(future_event.id)
    end

    it "returns nil and starts nothing when no candidate matches" do
      expect(described_class.start_for_destination!("Random Address", user)).to be_nil
      expect(described_class.active?(user)).to be(false)
    end

    it "returns nil when a trip is already active (won't replace mid-trip)" do
      described_class.start!(future_event, user)
      expect(described_class.start_for_destination!("Costco", user)).to be_nil
    end

    it "ignores events outside the lookahead window" do
      future_event.update!(start_at: 10.hours.from_now, end_at: 10.hours.from_now + 30.minutes)
      expect(described_class.start_for_destination!("Costco", user, lookahead: 4.hours)).to be_nil
    end

    it "ignores events without before_legs (no waypoint chain)" do
      future_event.update_columns(metadata: { "travel" => { "travel_minutes" => 10 } })
      expect(described_class.start_for_destination!("Office", user)).to be_nil
    end
  end

  describe ".arrived_at_current_stop?" do
    let(:address_book) { instance_double("AddressBook") }

    before do
      allow(user).to receive(:address_book).and_return(address_book)
      described_class.start!(item, user)
    end

    # AddressBook#geocode returns a 2-element [lat, lng] ARRAY in real
    # use (app/service/address_book.rb:273-275). The earlier rev of this
    # spec stubbed a hash, which masked a shape bug in TripState.
    it "is true when the reported coord is within ~500m of the geocoded stop" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5000, -111.9000])
      expect(described_class.arrived_at_current_stop?(user, reported_loc: [40.5001, -111.9001])).to be(true)
    end

    it "is false when the reported coord is far from the geocoded stop" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      expect(described_class.arrived_at_current_stop?(user, reported_loc: [42.0, -112.0])).to be(false)
    end

    it "is false when geocoding returns nil" do
      allow(address_book).to receive(:geocode).with("Costco").and_return(nil)
      expect(described_class.arrived_at_current_stop?(user, reported_loc: [40.5, -111.9])).to be(false)
    end

    it "is false when there's no active trip" do
      described_class.finish!(user)
      expect(described_class.arrived_at_current_stop?(user, reported_loc: [40.5, -111.9])).to be(false)
    end

    it "falls back to user.caches[:car_data][:location] when no reported_loc is passed" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      user.caches.set(:car_data, { location: { lat: 40.5001, lng: -111.9001 } })
      expect(described_class.arrived_at_current_stop?(user)).to be(true)
    end

    it "is false when neither reported_loc nor car_data location is present" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      expect(described_class.arrived_at_current_stop?(user)).to be(false)
    end
  end

  describe ".car_at?" do
    let(:address_book) { instance_double("AddressBook") }

    before do
      allow(user).to receive(:address_book).and_return(address_book)
      # Default: no saved contact matches — resolution falls through to geocode.
      allow(address_book).to receive(:match_contact).and_return(nil)
    end

    # `street` is only a label here — the geofence reads lat/lng.
    def saved_contact(name, *locs)
      user.contacts.create!(name: name).tap { |contact|
        locs.each_with_index do |(lat, lng), idx|
          contact.addresses.create!(
            user: user, primary: idx.zero?, street: "#{name} #{idx}", lat: lat, lng: lng,
          )
        end
      }
    end

    it "resolves a saved contact name (e.g. 'Home') to its address, not a raw geocode" do
      home = saved_contact("Home", [40.5, -111.9])
      allow(address_book).to receive(:match_contact).with("Home").and_return(home)
      # A contact-resolved destination must NOT hit geocode (geocode("Home")
      # never lands on the actual house — the bug this guards).
      expect(address_book).not_to receive(:geocode)
      user.caches.set(:car_data, { location: { lat: 40.5001, lng: -111.9001 } })
      expect(described_class.car_at?("Home", user: user)).to be(true)
    end

    it "matches a non-primary address, so a chain's other branch still counts" do
      # Quick Quack has two branches. The primary is Herriman; the wash
      # actually driven to is the Lehi one, ~9mi away. Testing only the
      # primary is what made the Car Wash auto-complete miss every visit.
      wash = saved_contact("CarWash", [40.508319, -112.026813], [40.413689, -111.908874])
      allow(address_book).to receive(:match_contact).with("Quick Quack").and_return(wash)
      user.caches.set(:car_data, { location: { lat: 40.413712, lng: -111.908876 } })
      expect(described_class.car_at?("Quick Quack", user: user)).to be(true)
    end

    it "is false when the car is at neither branch of a multi-address contact" do
      wash = saved_contact("CarWash", [40.508319, -112.026813], [40.413689, -111.908874])
      allow(address_book).to receive(:match_contact).with("Quick Quack").and_return(wash)
      user.caches.set(:car_data, { location: { lat: 40.480398, lng: -111.998186 } })
      expect(described_class.car_at?("Quick Quack", user: user)).to be(false)
    end

    it "ignores a contact address with no coords rather than counting it as a match" do
      contact = saved_contact("Vets", [40.5, -111.9])
      contact.addresses.create!(user: user, street: "No coords", lat: nil, lng: nil)
      allow(address_book).to receive(:match_contact).with("Vets").and_return(contact)
      user.caches.set(:car_data, { location: { lat: 42.0, lng: -112.0 } })
      expect(described_class.car_at?("Vets", user: user)).to be(false)
    end

    it "is true when the car's cached coord is within ~500m of the geocoded destination" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      user.caches.set(:car_data, { location: { lat: 40.5001, lng: -111.9001 } })
      expect(described_class.car_at?("Costco", user: user)).to be(true)
    end

    it "is false when the car is far from the destination" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      user.caches.set(:car_data, { location: { lat: 42.0, lng: -112.0 } })
      expect(described_class.car_at?("Costco", user: user)).to be(false)
    end

    it "is false when destination is blank (no destination = never 'already there')" do
      expect(described_class.car_at?(nil, user: user)).to be(false)
      expect(described_class.car_at?("",  user: user)).to be(false)
    end

    it "is false when geocoding returns nil" do
      allow(address_book).to receive(:geocode).with("Nowhere").and_return(nil)
      user.caches.set(:car_data, { location: { lat: 40.5, lng: -111.9 } })
      expect(described_class.car_at?("Nowhere", user: user)).to be(false)
    end

    it "is false when there's no car_data location" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      expect(described_class.car_at?("Costco", user: user)).to be(false)
    end
  end

  describe ".car_navigating_to?" do
    let(:address_book) { instance_double("AddressBook") }

    before do
      allow(user).to receive(:address_book).and_return(address_book)
      allow(address_book).to receive(:match_contact).and_return(nil)
    end

    it "is true when the active trip destination is within ~500m of the candidate" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      user.caches.set(:car_data, { trip: { destination: { lat: 40.5001, lng: -111.9001 } } })
      expect(described_class.car_navigating_to?("Costco", user: user)).to be(true)
    end

    it "is false when the active trip is heading somewhere else" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      user.caches.set(:car_data, { trip: { destination: { lat: 42.0, lng: -112.0 } } })
      expect(described_class.car_navigating_to?("Costco", user: user)).to be(false)
    end

    it "is false when there's no active trip" do
      allow(address_book).to receive(:geocode).with("Costco").and_return([40.5, -111.9])
      user.caches.set(:car_data, {})
      expect(described_class.car_navigating_to?("Costco", user: user)).to be(false)
    end

    it "is false when destination is blank" do
      expect(described_class.car_navigating_to?(nil, user: user)).to be(false)
      expect(described_class.car_navigating_to?("",  user: user)).to be(false)
    end

    it "is false when geocoding returns nil" do
      allow(address_book).to receive(:geocode).with("Nowhere").and_return(nil)
      user.caches.set(:car_data, { trip: { destination: { lat: 40.5, lng: -111.9 } } })
      expect(described_class.car_navigating_to?("Nowhere", user: user)).to be(false)
    end
  end

  # Whether the car is going ANYWHERE — what a scheduled navigation checks
  # before it retargets a drive the person is already following.
  describe ".car_routing?" do
    it "is true whenever there's an active trip section" do
      user.caches.set(:car_data, { trip: { destination: { lat: 40.5, lng: -111.9 }, minutes_to_arrival: 12.0 } })
      expect(described_class.car_routing?(user: user)).to be(true)
    end

    it "is true regardless of WHERE the car is headed, without geocoding anything" do
      expect(user).not_to receive(:address_book)
      user.caches.set(:car_data, { trip: { destination: { lat: 12.3, lng: 45.6 } } })
      expect(described_class.car_routing?(user: user)).to be(true)
    end

    # TeslaCacheStore#compose_trip drops the section outright when nav ends,
    # so absence is the signal — nothing here re-derives it from stale lat/lng.
    it "is false once nav has ended and the section is gone" do
      user.caches.set(:car_data, { location: { lat: 40.5, lng: -111.9 } })
      expect(described_class.car_routing?(user: user)).to be(false)
    end

    it "is false with no car data at all" do
      user.caches.set(:car_data, {})
      expect(described_class.car_routing?(user: user)).to be(false)
    end
  end
end
