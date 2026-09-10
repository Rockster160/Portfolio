require "rails_helper"

# Locks in the side-effect detections owned by TeslaTelemetry: the Jil
# triggers that fire on real state changes (drive start/stop, charge
# transition, HVAC on/off, trip start/update/end), and the tire-pressure
# chore-maintenance check. All raw recording / projection lives in
# TeslaCacheStore and is covered there.
RSpec.describe TeslaTelemetry do
  let(:user) { User.me }

  before do
    [:tesla_endpoint, :tesla_telemetry, :car_data].each do |key|
      user.caches.find_or_create_by!(key: key).update!(data: {})
    end
    allow(::TeslaCommand).to receive(:broadcast)
    # Stub one level below Jil.trigger so RSpec's verify_partial_doubles
    # doesn't choke on the kwargs-vs-positional hash binding when we call
    # Jil.trigger(user, :scope, { ... }). Jil.trigger itself runs normally
    # and forwards to Jil::Executor.trigger, where we capture the call.
    @triggers = []
    allow(::Jil::Executor).to receive(:trigger) { |*a, **k|
      @triggers << [a, k]
      nil
    }
    allow_any_instance_of(AddressBook).to receive(:find_contact_near).and_return(nil)
    allow_any_instance_of(AddressBook).to receive(:reverse_geocode).and_return(nil)
  end

  def seed_endpoint(snapshot)
    user.caches.set(:tesla_endpoint, { current: snapshot, timestamp: 1 })
  end

  def seed_car_data(snapshot)
    user.caches.set(:car_data, snapshot)
  end

  delegate :process, to: :described_class

  def triggered?(scope, data_match=nil)
    @triggers.any? { |(args, _kw)|
      next false unless args[1] == scope

      data_match.nil? || data_match.call(args[2])
    }
  end

  describe "envelope unwrapping" do
    it "reads from the inner :data hash when given Fleet Telemetry's record_payload shape" do
      process({ data: { ChargeState: "Charging" }, metadata: { vin: "X" }, msg: "record_payload" })
      expect(user.caches.get(:car_data).dig(:charging, :state)).to eq("Charging")
    end

    it "handles a flat hash" do
      process(ChargeState: "Idle")
      expect(user.caches.get(:car_data).dig(:charging, :state)).to eq("Idle")
    end

    it "tolerates Fleet Telemetry's alert envelope where :data is an Array (no Symbol-into-Integer crash)" do
      # Real-world shape from Fleet Telemetry's alert/error payloads —
      # used to blow up every detect_* via `@raw.dig(:data, :Field)`
      # because Array#dig refuses a Symbol index.
      seed_car_data(drive: { speed_mph: 0 })
      expect { process({ data: [{ name: "VCFRONT_a460_railVoltage" }], msg: "alerts" }) }.not_to raise_error
      expect(triggered?(:tesla_drive_start)).to be(false)
      expect(triggered?(:tesla_parked)).to be(false)
    end
  end

  describe "#detect_hvac_changes" do
    it "fires :tesla_hvac_on when HvacPower transitions to on" do
      seed_car_data(climate: { hvac_on: false })
      process(HvacPower: "HvacPowerStateOn")
      expect(triggered?(:tesla_hvac_on)).to be(true)
    end

    it "fires :tesla_hvac_off when HvacPower transitions to off" do
      seed_car_data(climate: { hvac_on: true })
      process(HvacPower: "HvacPowerStateOff")
      expect(triggered?(:tesla_hvac_off)).to be(true)
    end

    it "does NOT fire when HvacPower stays the same" do
      seed_car_data(climate: { hvac_on: true })
      process(HvacPower: "HvacPowerStateOn")
      expect(triggered?(:tesla_hvac_on)).to be(false)
      expect(triggered?(:tesla_hvac_off)).to be(false)
    end

    it "does NOT fire when HvacPower isn't in the inbound record" do
      seed_car_data(climate: { hvac_on: true })
      process(VehicleSpeed: 10)
      expect(triggered?(:tesla_hvac_off)).to be(false)
    end
  end

  describe "#detect_trip_changes" do
    let(:dest) { { latitude: 40.5, longitude: -111.5 } }
    let(:other_dest) { { latitude: 41.0, longitude: -112.0 } }

    it "fires :tesla_trip_started when destination appears" do
      seed_car_data(trip: nil)
      seed_endpoint(drive_state: {
        active_route_latitude:           40.5,
        active_route_longitude:          -111.5,
        active_route_miles_to_arrival:   5.0,
        active_route_minutes_to_arrival: 10.0,
      })
      process(DestinationLocation: dest, MilesToArrival: 5.0, MinutesToArrival: 10.0)
      expect(triggered?(:tesla_trip_started) { |d| d.key?(:destination_lat) }).to be(true)
    end

    it "fires :tesla_trip_updated when destination changes to a new location" do
      seed_car_data(trip: { destination: { lat: 40.5, lng: -111.5 } })
      seed_endpoint(drive_state: {
        active_route_latitude:           41.0,
        active_route_longitude:          -112.0,
        active_route_miles_to_arrival:   8.0,
        active_route_minutes_to_arrival: 15.0,
      })
      process(DestinationLocation: other_dest)
      expect(triggered?(:tesla_trip_updated) { |d| d.key?(:destination_lat) }).to be(true)
    end

    it "does NOT re-fire trip_updated for tiny GPS jitter" do
      seed_car_data(trip: { destination: { lat: 40.5, lng: -111.5 } })
      process(DestinationLocation: { latitude: 40.5001, longitude: -111.5001 })
      expect(triggered?(:tesla_trip_updated)).to be(false)
    end
  end

  describe "#detect_drive_changes" do
    it "fires :tesla_drive_start when speed goes 0 → positive" do
      seed_car_data(drive: { speed_mph: 0 })
      process(VehicleSpeed: 35)
      expect(triggered?(:tesla_drive_start) { |d| d == { speed: 35 } }).to be(true)
    end

    it "fires :tesla_drive_stop when speed goes positive → 0" do
      seed_car_data(drive: { speed_mph: 35 })
      process(VehicleSpeed: 0)
      expect(triggered?(:tesla_drive_stop)).to be(true)
    end

    it "skips '<invalid>' VehicleSpeed records (sensor offline, not a real stop)" do
      seed_car_data(drive: { speed_mph: 35 })
      process(VehicleSpeed: "<invalid>")
      expect(triggered?(:tesla_drive_stop)).to be(false)
    end
  end

  describe "#detect_shift_changes" do
    it "fires :tesla_shift on any gear transition with { shift, previous }" do
      seed_car_data(drive: { speed_mph: 0, shift: "D" })
      process(Gear: "ShiftStateN")
      expect(triggered?(:tesla_shift) { |d| d[:shift] == "N" && d[:previous] == "D" }).to be(true)
    end

    it "fires :tesla_shift on transition into P (alongside :tesla_parked)" do
      seed_car_data(drive: { speed_mph: 0, shift: "D" })
      process(Gear: "ShiftStateP")
      expect(triggered?(:tesla_shift) { |d| d[:shift] == "P" }).to be(true)
      expect(triggered?(:tesla_parked)).to be(true)
    end

    it "does NOT fire when shift is unchanged" do
      seed_car_data(drive: { speed_mph: 0, shift: "N" })
      process(Gear: "ShiftStateN")
      expect(triggered?(:tesla_shift)).to be(false)
    end

    it "does NOT fire on '<invalid>' Gear records" do
      seed_car_data(drive: { speed_mph: 0, shift: "D" })
      process(Gear: "<invalid>")
      expect(triggered?(:tesla_shift)).to be(false)
    end
  end

  describe "#detect_park_changes" do
    it "fires :tesla_parked on shift INTO P (from D)" do
      seed_car_data(drive: { speed_mph: 0, shift: "D" })
      process(Gear: "ShiftStateP")
      expect(triggered?(:tesla_parked) { |d| d[:shift] == "P" && d[:previous] == "D" }).to be(true)
    end

    it "accepts short-form 'P' shift values" do
      seed_car_data(drive: { speed_mph: 0, shift: "D" })
      process(Gear: "P")
      expect(triggered?(:tesla_parked)).to be(true)
    end

    it "does NOT fire when shift stays at P" do
      seed_car_data(drive: { speed_mph: 0, shift: "P", parked: true })
      process(Gear: "ShiftStateP")
      expect(triggered?(:tesla_parked)).to be(false)
    end

    it "does NOT fire on transitions to non-park gears (D, R, N)" do
      seed_car_data(drive: { speed_mph: 0, shift: "P" })
      process(Gear: "ShiftStateD")
      expect(triggered?(:tesla_parked)).to be(false)
    end

    it "does NOT fire on '<invalid>' Gear records" do
      seed_car_data(drive: { speed_mph: 0, shift: "D" })
      process(Gear: "<invalid>")
      expect(triggered?(:tesla_parked)).to be(false)
    end

    it "does NOT fire when Gear isn't in the inbound record at all" do
      seed_car_data(drive: { speed_mph: 0, shift: "D" })
      process(VehicleSpeed: 5)
      expect(triggered?(:tesla_parked)).to be(false)
    end
  end

  describe "#check_tire_pressure" do
    let(:chores) { instance_double(List, add: nil, remove: nil) }

    before { allow(user).to receive(:list_by_name).with(:Chores).and_return(chores) }

    it "does NOT add chore items when all tires are healthy" do
      seed_endpoint(vehicle_state: {
        tpms_pressure_fl:     3.0,
        tpms_pressure_fr:     3.1,
        tpms_pressure_rl:     2.95,
        tpms_pressure_rr:     2.975,
        tpms_soft_warning_fl: false,
        tpms_soft_warning_fr: false,
        tpms_soft_warning_rl: false,
        tpms_soft_warning_rr: false,
      })
      process(ChargeState: "Idle")
      expect(chores).not_to have_received(:add)
    end

    it "flags only the soft-warned + truly-low tire" do
      seed_endpoint(vehicle_state: {
        tpms_pressure_fl:     41.0,
        tpms_pressure_fr:     41.5,
        tpms_pressure_rl:     35.0,
        tpms_pressure_rr:     42.0,
        tpms_soft_warning_fl: false,
        tpms_soft_warning_fr: false,
        tpms_soft_warning_rl: true,
        tpms_soft_warning_rr: false,
      })
      process(ChargeState: "Idle")
      expect(chores).to have_received(:add).with("Back Left tire pressure low")
      expect(chores).not_to have_received(:add).with(/Front/)
    end
  end

  # The car is the only thing in the house that knows it went somewhere
  # without Rocco. Scoped to the home boundary: every other place name that
  # changes mid-drive is a city, not a leg.
  describe "crossing the home boundary" do
    let(:home) { [40.48038, -111.99827] }
    let(:away) { [40.52292, -111.85389] }

    before { allow_any_instance_of(AddressBook).to receive(:home).and_return(instance_double(Address, loc: home)) }

    # filter_map, not select.pluck(2): the rows are [args, kwargs] pairs, and
    # `pluck(2)` indexes the PAIR rather than the args inside it.
    def travel_triggers
      @triggers.filter_map { |(args, _kw)| args[2] if args[1] == :trytravel }
    end

    def travel_trigger
      travel_triggers.first
    end

    it "reports the car leaving" do
      seed_car_data(location: { lat: home.first, lng: home.last, name: "Home" })

      process(Location: { latitude: away.first, longitude: away.last })

      expect(travel_trigger).to include(action: :departed, source: :tesla)
    end

    it "reports the car coming back" do
      seed_car_data(location: { lat: away.first, lng: away.last, name: "Draper" })

      process(Location: { latitude: home.first, longitude: home.last })

      expect(travel_trigger).to include(action: :arrived, source: :tesla)
    end

    it "says nothing while it sits on the drive" do
      seed_car_data(location: { lat: home.first, lng: home.last, name: "Home" })

      process(Location: { latitude: home.first + 0.00001, longitude: home.last })

      expect(travel_trigger).to be_nil
    end

    # A city name changing halfway through a drive is not a leg.
    it "says nothing about the places it passes through" do
      seed_car_data(location: { lat: away.first, lng: away.last, name: "Draper" })

      process(Location: { latitude: 40.76379, longitude: -111.90071 })

      expect(travel_trigger).to be_nil
    end

    # The first push after a deploy has no previous position to have crossed
    # from, and must not be read as an arrival.
    it "says nothing when there is no previous position" do
      process(Location: { latitude: home.first, longitude: home.last })

      expect(travel_trigger).to be_nil
    end

    it "says nothing on a push that carries no position" do
      seed_car_data(location: { lat: home.first, lng: home.last, name: "Home" })

      process(ChargeState: "Idle")

      expect(travel_trigger).to be_nil
    end

    # A pairing in the garage no longer announces on its own, and the geofence
    # has never once sent a departure — so this is the only thing that reports
    # Rocco leaving his own house. Bluetooth reaches ~10m and the boundary
    # ~100m, so a pairing that survives the crossing means he is in the car.
    describe "whether the phone went with it" do
      before { seed_car_data(location: { lat: home.first, lng: home.last, name: "Home" }) }

      def leave!
        process(Location: { latitude: away.first, longitude: away.last })
      end

      it "reports him leaving too when the phone is still paired" do
        allow(::LocationCache).to receive(:driving?).and_return(true)

        leave!

        expect(travel_triggers.pluck(:source)).to eq(%i[tesla phone])
      end

      # 2026-09-10: last Bluetooth edge 10:22:15, car crossed around 10:23
      # unpaired. Chelsea went, he didn't.
      it "reports only the car when the pairing dropped in the driveway" do
        allow(::LocationCache).to receive(:driving?).and_return(false)

        leave!

        expect(travel_triggers.pluck(:source)).to eq([:tesla])
      end

      # Corroborated by the car having actually driven off, so it is not the
      # raw radio edge that gets refused at home.
      it "does not label the corroborated report as Bluetooth" do
        allow(::LocationCache).to receive(:driving?).and_return(true)

        leave!

        expect(travel_triggers.last).not_to have_key(:via)
      end

      # Same geometry the other way: driving himself home, the pairing holds
      # through the crossing.
      it "reports him arriving too when he drove himself home" do
        seed_car_data(location: { lat: away.first, lng: away.last, name: "Draper" })
        allow(::LocationCache).to receive(:driving?).and_return(true)

        process(Location: { latitude: home.first, longitude: home.last })

        expect(travel_triggers.pluck(:source)).to eq(%i[tesla phone])
      end

      # Chelsea coming back: at the boundary his phone is still a hundred
      # metres away indoors, far out of Bluetooth range.
      it "reports only the car when he was never in it" do
        seed_car_data(location: { lat: away.first, lng: away.last, name: "Draper" })
        allow(::LocationCache).to receive(:driving?).and_return(false)

        process(Location: { latitude: home.first, longitude: home.last })

        expect(travel_triggers.pluck(:source)).to eq([:tesla])
      end
    end
  end
end
