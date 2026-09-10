require "rails_helper"

# Bluetooth reaches into the garage. On 2026-09-10 the radio connected and
# dropped five times in three minutes from the same spot — 10:19:39, 10:19:47,
# 10:20:18, 10:20:25, 10:21:08, 10:21:16, 10:21:37, 10:21:45, 10:22:08,
# 10:22:15 — while Rocco was inside the house and Chelsea was backing the car
# out. The flap guard swallowed nine of those ten edges. The first had nothing
# before it to be a flap against, so it recorded a departure (action_event
# 52194) that stood unmatched for the rest of the day, and took Task 46
# ("Departed House") and Task 50 ("Arrival Commands") with it.
#
# At home the phone's own geofence answers this question, and answers it about
# the PERSON. Bluetooth only pairs with the car, so at home it has nothing to
# add and every reason to be wrong.
RSpec.describe LocationCache do
  let(:user) { User.me }
  let(:home) { [40.48038, -111.99827] }
  let(:garage) { [40.480456, -111.998311] } # the coordinate all ten edges reported
  let(:town) { [40.76379, -111.90071] }
  let(:book) { instance_double(AddressBook, home: instance_double(Address, loc: home)) }

  # `Jil.trigger(user, scope, data = {}, auth:, auth_id:)` takes the payload
  # positionally, and every real caller passes it that way. A verifying double
  # reads a trailing hash against a signature that also has keywords and splits
  # it off as those keywords, rejecting a call Ruby itself is happy with.
  around { |example| without_partial_double_verification { example.run } }

  before do
    @fired = []
    allow(::Jil).to receive(:trigger) { |_user, _scope, data| @fired << data }
    allow(User).to receive(:me).and_return(user)
    allow(user).to receive(:address_book).and_return(book)
    allow(described_class).to receive(:current_location_name).and_return("Home")
    user.caches.dig_set(:driving, :is_driving, false)
    user.caches.dig_set(:driving, :last_transition, nil)
  end

  def actions
    @fired.map { |data| data[:action] }
  end

  def parked_at(loc, name: "Home")
    user.caches.dig_set(:driving, :recent_locations, [{ loc: loc, at: 1, name: name }])
  end

  # The garage rule itself lives in TravelResolver, because the same Shortcut
  # queues a copy of every one of these for replay and that copy never comes
  # through here. What this file owns is that the report says how it was made,
  # so the resolver has something to judge.
  it "says how the report was made" do
    parked_at(town, name: "Salt Lake City")

    described_class.set_driving(true, coord: town)

    expect(@fired.first).to include(source: :phone, via: :bluetooth)
  end

  describe "away from home" do
    it "reports setting off" do
      parked_at(town, name: "Salt Lake City")

      described_class.set_driving(true, coord: town)

      expect(actions).to eq([:departed])
    end

    # Both halves are reported; TravelResolver is what decides the pairing at
    # Home was the garage and drops it.
    it "reports arriving somewhere that isn't home" do
      parked_at(home)
      described_class.set_driving(true, coord: home)
      parked_at(town, name: "Salt Lake City")

      described_class.set_driving(false, coord: town)

      expect(actions).to eq(%i[departed arrived])
    end

    # The guard that earns its keep everywhere the geofence doesn't reach —
    # a parking garage drops and re-pairs the same way the home one does.
    it "swallows a flap in a car park" do
      parked_at(town, name: "Salt Lake City")

      described_class.set_driving(true, coord: town)
      described_class.set_driving(false, coord: town)

      expect(actions).to eq([:departed])
    end

    it "reports a real leg that ends somewhere else" do
      parked_at(town, name: "Salt Lake City")
      described_class.set_driving(true, coord: town)

      travel_to(40.minutes.from_now) do
        described_class.set_driving(false, coord: [40.52292, -111.85389])
      end

      expect(actions).to eq(%i[departed arrived])
    end
  end

  describe "the coordinate it reports with" do
    # `set` drops a coordinate near the last one it kept, so the freshest thing
    # in `recent_locations` can be days old while the phone is saying exactly
    # where it is. Event 52194 went out stamped with the previous evening's
    # arrival coordinate because the transition read the cache instead of the
    # report.
    it "uses what the phone just said, not what the cache last kept" do
      parked_at([40.48042942650596, -111.998075733243])

      described_class.set_driving(true, coord: town)

      expect(@fired.first).to include(lat: town.first, lng: town.last)
    end

    it "falls back to the cache when the phone sent no coordinate" do
      parked_at(town, name: "Salt Lake City")

      described_class.set_driving(true)

      expect(@fired.first).to include(lat: town.first, lng: town.last)
    end
  end

  describe "at_home?" do
    it "is true for the garage, a few metres off the pin" do
      expect(described_class.at_home?(garage)).to be(true)
    end

    it "is false across town" do
      expect(described_class.at_home?(town)).to be(false)
    end

    # Nothing to compare against is not a reason to answer yes.
    it "is false when the address book has no home in it" do
      allow(book).to receive(:home).and_return(nil)

      expect(described_class.at_home?(garage)).to be(false)
    end

    it "is false with no coordinate" do
      expect(described_class.at_home?(nil)).to be(false)
    end
  end
end
