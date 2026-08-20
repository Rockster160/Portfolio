require "rails_helper"

# The car's Bluetooth connects, drops and reconnects inside half a minute, and
# each edge emitted a travel event — so a departure and an arrival at Home
# landed from identical coordinates, on five days in the last six
# (action_events 51331/51332, 51440/51441, 51501/51502, 51558/51559,
# 51576/51577, between 8 and 31 seconds apart).
#
# Nobody went anywhere, but Task 50 ("Arrival Commands") listens on both and
# drains the queued commands for that place when it runs.
RSpec.describe LocationCache do
  let(:user) { User.me }
  let(:home) { [40.48038, -111.99827] }
  let(:town) { [40.76379, -111.90071] }

  # `Jil.trigger(user, scope, data = {}, auth:, auth_id:)` takes the payload
  # positionally, and every real caller passes it that way. A verifying double
  # reads a trailing hash against a signature that also has keywords and splits
  # it off as those keywords, rejecting a call Ruby itself is happy with.
  around { |example| without_partial_double_verification { example.run } }

  before do
    @fired = []
    allow(::Jil).to receive(:trigger) { |_user, _scope, data| @fired << data }
    allow(User).to receive(:me).and_return(user)
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

  it "reports a departure when the car sets off" do
    parked_at(home)

    described_class.driving = true

    expect(actions).to eq([:departed])
  end

  describe "a Bluetooth flap" do
    # Prod 51501/51502: departed 10:28:58, arrived 10:29:06, both at
    # 40.48038,-111.99827 to fourteen decimal places.
    it "does not report arriving back where it just left, seconds later" do
      parked_at(home)
      described_class.driving = true

      described_class.driving = false

      expect(actions).to eq([:departed])
    end

    # The radio really is off. It's the journey that didn't happen.
    it "still records that the car stopped" do
      parked_at(home)
      described_class.driving = true

      described_class.driving = false

      expect(described_class.driving?).to be(false)
    end

    # Each half is measured against the one before it rather than against the
    # last real journey, so the whole storm collapses to the first edge.
    it "swallows the reconnect that follows it" do
      parked_at(home)

      described_class.driving = true
      described_class.driving = false
      described_class.driving = true

      expect(actions).to eq([:departed])
    end
  end

  describe "what it must never swallow" do
    # A real leg ENDS somewhere else. This is the case a "has it actually
    # moved" gate would have got backwards: EVERY genuine departure leaves from
    # the exact coordinates of the arrival before it (51366 arrived Home at
    # 40.48049,-111.99816 and 51370 departed Home at the same figures), so a
    # distance check would refuse every real journey.
    it "reports arriving somewhere else, however fast the drive was" do
      parked_at(home)
      described_class.driving = true
      parked_at(town, name: "Salt Lake City")

      described_class.driving = false

      expect(actions).to eq(%i[departed arrived])
    end

    it "reports coming home after a real trip out" do
      parked_at(home)
      described_class.driving = true

      travel_to(40.minutes.from_now) do
        described_class.driving = false
      end

      expect(actions).to eq(%i[departed arrived])
    end

    it "reports setting off again from where the last trip ended" do
      parked_at(home)
      described_class.driving = true
      parked_at(town, name: "Salt Lake City")
      described_class.driving = false

      travel_to(20.minutes.from_now) do
        described_class.driving = true
      end

      expect(actions).to eq(%i[departed arrived departed])
    end

    it "reports normally when there's no previous transition to compare against" do
      parked_at(home)

      described_class.driving = true

      expect(actions).to eq([:departed])
    end

    # Nothing to compare coordinates with means nothing to suppress on.
    it "reports normally when the phone has no recent location at all" do
      user.caches.dig_set(:driving, :recent_locations, [])
      described_class.driving = true
      described_class.driving = false

      expect(actions).to eq(%i[departed arrived])
    end
  end
end
