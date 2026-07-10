require "rails_helper"

# Locks in the cache architecture and the projection from raw caches → the
# clean :car_data schema:
#   :tesla_telemetry → raw deep-merged telemetry (current + section_ts + history)
#   :tesla_endpoint  → last vehicle_data poll response
#   :car_data        → projected/normalized view: location, battery, charging,
#                      drive, trip, climate, doors, windows, tires, odometer.
# Every transformation (BAR→PSI, C→F, window enum → bool, HvacPower → bool,
# ChargeState ClearFaults filter, <invalid> sentinel stripping) happens during
# compose. Raw caches preserve what Tesla sent.
RSpec.describe TeslaCacheStore do
  let(:user) { User.me }

  before do
    [:tesla_telemetry, :tesla_endpoint, :car_data].each do |key|
      user.caches.find_or_create_by!(key: key).update!(data: {})
    end
    allow_any_instance_of(AddressBook).to receive(:find_contact_near).and_return(nil)
    allow_any_instance_of(AddressBook).to receive(:reverse_geocode).and_return(nil)
  end

  def telemetry_cache = user.caches.get(:tesla_telemetry)
  def endpoint_cache  = user.caches.get(:tesla_endpoint)
  def car_data        = user.caches.get(:car_data) || {}

  describe "raw telemetry history + current" do
    it "stores history exactly as Tesla sent it — no formatting" do
      payload = { VehicleSpeed: "<invalid>", TpmsPressureFl: 3.0, FdWindow: "WindowStateClosed" }
      described_class.record_telemetry(payload)

      entry = telemetry_cache[:history].first
      expect(entry[:data]).to eq(payload)
    end

    it "strips '<invalid>' leaves before merging into current (so prior good values survive)" do
      described_class.record_telemetry(TpmsPressureFl: 3.0)
      described_class.record_telemetry(TpmsPressureFl: "<invalid>")

      expect(telemetry_cache[:current][:TpmsPressureFl]).to eq(3.0)
    end

    it "rewrites '<invalid>' VehicleSpeed to 0 pre-merge — sensor-offline = parked, not 'no update'" do
      described_class.record_telemetry(VehicleSpeed: 35)
      described_class.record_telemetry(VehicleSpeed: "<invalid>")

      expect(telemetry_cache[:current][:VehicleSpeed]).to eq(0)
    end

    it "strips '<invalid>' nested leaves without losing the rest of a sibling field" do
      described_class.record_telemetry(DoorState: { DriverFront: true, TrunkRear: false })
      described_class.record_telemetry(DoorState: { DriverFront: "<invalid>" })

      expect(telemetry_cache[:current][:DoorState]).to eq({ DriverFront: true, TrunkRear: false })
    end

    it "accumulates partial pushes via deep_merge" do
      described_class.record_telemetry(InsideTemp: 22.5)
      described_class.record_telemetry(OutsideTemp: 18.0)
      described_class.record_telemetry(InsideTemp: 23.0)

      expect(telemetry_cache[:current]).to include(InsideTemp: 23.0, OutsideTemp: 18.0)
    end

    it "caps history at HISTORY_LIMIT, newest first" do
      (described_class::HISTORY_LIMIT + 3).times do |i|
        described_class.record_telemetry(VehicleSpeed: i + 1)
      end

      history = telemetry_cache[:history]
      expect(history.length).to eq(described_class::HISTORY_LIMIT)
      expect(history.first[:data][:VehicleSpeed]).to eq(described_class::HISTORY_LIMIT + 3)
    end

    it "stamps section_ts when telemetry record includes a field for that section" do
      described_class.record_telemetry(HvacPower: "HvacPowerStateOn")
      expect(telemetry_cache[:section_ts][:climate]).to be_present
      expect(telemetry_cache[:section_ts][:drive]).to be_nil
    end
  end

  describe "car_data projection" do
    it "exposes battery from the endpoint poll" do
      described_class.record_endpoint(charge_state: { battery_level: 87, battery_range: 250.4, timestamp: 1 })
      expect(car_data[:battery]).to include(pct: 87, range_mi: 250.4)
    end

    it "exposes climate.hvac_on as true when telemetry says HvacPowerStateOn" do
      described_class.record_telemetry(HvacPower: "HvacPowerStateOn", InsideTemp: 22.0)
      expect(car_data.dig(:climate, :hvac_on)).to be(true)
      expect(car_data.dig(:climate, :inside_f)).to eq(71.6) # 22C → 71.6F
    end

    it "exposes climate.hvac_on as false for HvacPowerStateOff" do
      described_class.record_telemetry(HvacPower: "HvacPowerStateOff")
      expect(car_data.dig(:climate, :hvac_on)).to be(false)
    end

    it "falls back to endpoint is_climate_on when telemetry hasn't sent HvacPower" do
      described_class.record_endpoint(climate_state: { is_climate_on: true })
      expect(car_data.dig(:climate, :hvac_on)).to be(true)
    end

    it "exposes trip data from the endpoint poll when nav is active" do
      described_class.record_endpoint(drive_state: {
        active_route_latitude:            40.5,
        active_route_longitude:           -111.5,
        active_route_miles_to_arrival:    2.34,
        active_route_minutes_to_arrival:  6.7,
        timestamp:                        1,
      })
      expect(car_data[:trip]).to include(
        miles_to_arrival:   2.34,
        minutes_to_arrival: 6.7,
      )
      expect(car_data.dig(:trip, :destination)).to include(lat: 40.5, lng: -111.5)
    end

    it "resolves trip.destination.name from the address book (used by the dashboard route line)" do
      home = double(name: "Home", present?: true)
      allow_any_instance_of(AddressBook).to receive(:find_contact_near).with([40.5, -111.5]).and_return(home)
      described_class.record_endpoint(drive_state: {
        active_route_latitude:           40.5,
        active_route_longitude:          -111.5,
        active_route_miles_to_arrival:   1.0,
        active_route_minutes_to_arrival: 2.0,
      })
      expect(car_data.dig(:trip, :destination, :name)).to eq("Home")
    end

    it "returns no trip when nav is cleared (endpoint drops miles+minutes even if stale lat/lng linger)" do
      # Simulate a prior active route recorded in telemetry, then a nav-clear
      # reflected in the endpoint (miles/minutes gone, stale coords remain).
      described_class.record_telemetry(
        DestinationLocation: { latitude: 40.4, longitude: -112.0 },
        MilesToArrival:      1.85,
        MinutesToArrival:    3.5,
      )
      described_class.record_endpoint(drive_state: {
        active_route_latitude:            40.4,
        active_route_longitude:           -112.0,
        active_route_miles_to_arrival:    nil,
        active_route_minutes_to_arrival:  nil,
        timestamp:                        1,
      })

      expect(car_data[:trip]).to be_nil
    end

    describe "drive.shift normalization" do
      it "accepts Tesla's enum-string form (ShiftStateP)" do
        described_class.record_telemetry(Gear: "ShiftStateP")
        expect(car_data.dig(:drive, :shift)).to eq("P")
        expect(car_data.dig(:drive, :parked)).to be(true)
      end

      it "accepts the short single-letter form ('D')" do
        described_class.record_telemetry(Gear: "D")
        expect(car_data.dig(:drive, :shift)).to eq("D")
        expect(car_data.dig(:drive, :parked)).to be(false)
      end

      it "accepts the integer-as-string form ('2' → P)" do
        described_class.record_telemetry(Gear: "2")
        expect(car_data.dig(:drive, :shift)).to eq("P")
      end

      it "falls through to endpoint drive_state.shift_state when telemetry hasn't sent Gear" do
        described_class.record_endpoint(drive_state: { shift_state: "D", speed: 0, timestamp: 1 })
        expect(car_data.dig(:drive, :shift)).to eq("D")
      end

      it "drops unknown shift shapes (returns nil rather than poisoning .parked)" do
        described_class.record_telemetry(Gear: "ShiftStateQuasar")
        expect(car_data.dig(:drive, :shift)).to be_nil
        expect(car_data.dig(:drive, :parked)).to be(false)
      end

      it "telemetry Gear wins over endpoint shift_state (endpoint poll can be stale mid-drive)" do
        described_class.record_endpoint(drive_state: { shift_state: "P", speed: 0, timestamp: 1 })
        described_class.record_telemetry(Gear: "ShiftStateD", VehicleSpeed: 25)

        expect(car_data.dig(:drive, :shift)).to eq("D")
        expect(car_data.dig(:drive, :parked)).to be(false)
        expect(car_data.dig(:drive, :speed_mph)).to eq(25)
      end
    end

    it "filters 'ClearFaults' (transient pulse) from charging.state" do
      described_class.record_endpoint(charge_state: { battery_level: 50, charging_state: "Charging" })
      described_class.record_telemetry(ChargeState: "ClearFaults")
      expect(car_data.dig(:charging, :state)).to eq("Charging")
    end

    it "endpoint charging_state=Disconnected overrides stale telemetry Idle (Tesla doesn't push Disconnected via telemetry)" do
      described_class.record_telemetry(ChargeState: "Idle")
      described_class.record_endpoint(charge_state: { battery_level: 90, charging_state: "Disconnected" })
      expect(car_data.dig(:charging, :state)).to eq("Disconnected")
      expect(car_data.dig(:charging, :active)).to be(false)
    end

    it "fresh telemetry wins over a stale endpoint snapshot (timestamp-based)" do
      # Endpoint polled first (older), then telemetry pushes a live update.
      described_class.record_endpoint(charge_state: { battery_level: 30, charging_state: "Disconnected" })
      described_class.record_telemetry(ChargeState: "Enable")
      expect(car_data.dig(:charging, :state)).to eq("Enable")
      expect(car_data.dig(:charging, :active)).to be(true)
    end

    it "fresh endpoint wins over stale telemetry (unplug: tel goes silent at Idle, endpoint later polls Disconnected)" do
      described_class.record_telemetry(ChargeState: "Idle")
      # Simulate the endpoint poll landing after the tel Idle push (typical unplug sequence).
      described_class.record_endpoint(charge_state: { battery_level: 90, charging_state: "Disconnected" })
      expect(car_data.dig(:charging, :state)).to eq("Disconnected")
    end

    it "rewrites '<invalid>' Gear to ShiftStateP pre-merge (Tesla's key-out signal)" do
      described_class.record_telemetry(Gear: "ShiftStateR")
      described_class.record_telemetry(Gear: "<invalid>")
      expect(car_data.dig(:drive, :shift)).to eq("P")
      expect(car_data.dig(:drive, :parked)).to be(true)
    end

    it "maps DoorState (PascalCase telemetry) to descriptive keys in doors" do
      described_class.record_telemetry(DoorState: {
        DriverFront: true, TrunkFront: false, TrunkRear: true,
      })
      expect(car_data.dig(:doors, :driver_front)).to be(true)
      expect(car_data.dig(:doors, :frunk)).to be(false)
      expect(car_data.dig(:doors, :trunk)).to be(true)
    end

    it "normalizes window-state strings to bool open/closed (matching door key names)" do
      described_class.record_telemetry(FdWindow: "WindowStateClosed", FpWindow: "WindowStateVent")
      expect(car_data.dig(:windows, :driver_front)).to be(false)
      expect(car_data.dig(:windows, :passenger_front)).to be(true)
    end

    it "converts BAR tire pressures to PSI in tires section" do
      described_class.record_endpoint(vehicle_state: {
        tpms_pressure_fl: 3.0, tpms_pressure_fr: 3.1, tpms_pressure_rl: 2.95, tpms_pressure_rr: 2.975
      })
      expect(car_data.dig(:tires, :fl_psi)).to eq(43.5)
      expect(car_data.dig(:tires, :fr_psi)).to eq(45.0)
    end

    it "omits tire psi when sensor offline" do
      described_class.record_endpoint(vehicle_state: { tpms_pressure_fl: 3.0, tpms_pressure_fr: 0 })
      expect(car_data.dig(:tires, :fl_psi)).to eq(43.5)
      expect(car_data.dig(:tires, :fr_psi)).to be_nil
    end

    it "exposes per-tire soft/hard warnings from endpoint" do
      described_class.record_endpoint(vehicle_state: {
        tpms_pressure_fl: 3.0, tpms_soft_warning_fl: true, tpms_hard_warning_fl: false
      })
      expect(car_data.dig(:tires, :fl_soft)).to be(true)
      expect(car_data.dig(:tires, :fl_hard)).to be(false)
    end
  end

  describe "location overlay" do
    it "applies a partial Location (lat only) without clobbering existing lng" do
      described_class.record_endpoint(drive_state: { latitude: 40.0, longitude: -111.0 })
      described_class.record_telemetry(Location: { latitude: 40.5 })
      expect(car_data.dig(:location, :lat)).to eq(40.5)
      expect(car_data.dig(:location, :lng)).to eq(-111.0)
    end

    it "uses telemetry Location when both coords present" do
      described_class.record_telemetry(Location: { latitude: 40.5, longitude: -111.5 })
      expect(car_data.dig(:location, :lat)).to eq(40.5)
      expect(car_data.dig(:location, :lng)).to eq(-111.5)
    end

    it "sets location.name from matched contact when one is nearby" do
      contact = double(name: "Home", present?: true)
      allow_any_instance_of(AddressBook).to receive(:find_contact_near).and_return(contact)
      described_class.record_telemetry(Location: { latitude: 40.5, longitude: -111.5 })
      expect(car_data.dig(:location, :name)).to eq("Home")
    end

    it "falls back to reverse-geocoded city when no contact is near" do
      allow_any_instance_of(AddressBook).to receive(:find_contact_near).and_return(nil)
      allow_any_instance_of(AddressBook).to receive(:reverse_geocode).and_return("Salt Lake City")
      described_class.record_telemetry(Location: { latitude: 40.7, longitude: -111.9 })
      expect(car_data.dig(:location, :name)).to eq("Salt Lake City")
    end
  end
end
