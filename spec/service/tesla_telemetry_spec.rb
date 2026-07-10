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
        active_route_latitude:            40.5,
        active_route_longitude:           -111.5,
        active_route_miles_to_arrival:    5.0,
        active_route_minutes_to_arrival:  10.0,
      })
      process(DestinationLocation: dest, MilesToArrival: 5.0, MinutesToArrival: 10.0)
      expect(triggered?(:tesla_trip_started) { |d| d.key?(:destination_lat) }).to be(true)
    end

    it "fires :tesla_trip_updated when destination changes to a new location" do
      seed_car_data(trip: { destination: { lat: 40.5, lng: -111.5 } })
      seed_endpoint(drive_state: {
        active_route_latitude:            41.0,
        active_route_longitude:           -112.0,
        active_route_miles_to_arrival:    8.0,
        active_route_minutes_to_arrival:  15.0,
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
end
