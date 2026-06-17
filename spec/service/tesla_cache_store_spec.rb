require "rails_helper"

# Locks in the divided-responsibility cache architecture:
#   :tesla_telemetry → raw deep-merged telemetry (history + current both raw)
#   :tesla_endpoint  → raw deep-merged poll responses (history + current raw)
#   :car_data        → formatted/normalized/meta-augmented derived view
# Everything that transforms data (BAR→PSI, window strings → ints,
# ChargeState filtering, sentinel rejection, location_name lookup) happens
# in compose. The two source caches preserve exactly what Tesla sent.
RSpec.describe TeslaCacheStore do
  let(:user) { User.me }

  before do
    [:tesla_telemetry, :tesla_endpoint, :car_data].each do |key|
      user.caches.find_or_create_by!(key: key).update!(data: {})
    end
    # find_contact_near goes through the real address_book; stub so we
    # don't hit AR/Google in tests.
    allow_any_instance_of(AddressBook).to receive(:find_contact_near).and_return(nil)
    allow_any_instance_of(AddressBook).to receive(:reverse_geocode).and_return(nil)
  end

  def telemetry_cache = user.caches.get(:tesla_telemetry)
  def endpoint_cache  = user.caches.get(:tesla_endpoint)
  def car_data        = user.caches.get(:car_data) || {}

  describe "raw history + current" do
    it "stores history exactly as Tesla sent it — no formatting, no pruning" do
      payload = { VehicleSpeed: "<invalid>", TpmsPressureFl: 3.0, FdWindow: "WindowStateClosed" }
      described_class.record_telemetry(payload)

      entry = telemetry_cache[:history].first
      expect(entry[:data]).to eq(payload)
    end

    it "strips '<invalid>' leaves before merging into current (so prior good values survive)" do
      described_class.record_telemetry(VehicleSpeed: 35)
      described_class.record_telemetry(VehicleSpeed: "<invalid>")

      expect(telemetry_cache[:current][:VehicleSpeed]).to eq(35)
    end

    it "strips '<invalid>' nested leaves without losing the rest of a sibling field" do
      described_class.record_telemetry(DoorState: { DriverFront: true, TrunkRear: false })
      described_class.record_telemetry(DoorState: { DriverFront: "<invalid>" })

      # The known-good DriverFront stays; invalid is filtered.
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
  end

  describe "car_data compose: cleaning + normalization" do
    it "skips '<invalid>' sentinels so a sensor going offline doesn't crater car_data" do
      described_class.record_endpoint(drive_state: { speed: 35 })
      described_class.record_telemetry(VehicleSpeed: "<invalid>")

      # endpoint baseline still has speed=35; telemetry's invalid is ignored
      expect(car_data.dig(:drive_state, :speed)).to eq(35)
    end

    it "filters 'ClearFaults' (transient pulse) from charging_state" do
      described_class.record_endpoint(charge_state: { charging_state: "Charging" })
      described_class.record_telemetry(ChargeState: "ClearFaults")

      expect(car_data.dig(:charge_state, :charging_state)).to eq("Charging")
    end

    it "maps DoorState.TrunkFront/TrunkRear → ft/rt (the bug fix)" do
      described_class.record_telemetry(DoorState: {
        DriverFront: true, TrunkFront: false, TrunkRear: true,
      })

      expect(car_data.dig(:vehicle_state, :df)).to eq(true)
      expect(car_data.dig(:vehicle_state, :ft)).to eq(false)
      expect(car_data.dig(:vehicle_state, :rt)).to eq(true)
    end

    it "normalizes window-state strings to int 0/1" do
      described_class.record_telemetry(FdWindow: "WindowStateClosed", FpWindow: "WindowStateVent")

      expect(car_data.dig(:vehicle_state, :fd_window)).to eq(0)
      expect(car_data.dig(:vehicle_state, :fp_window)).to eq(1)
    end

    it "converts BAR tire pressures to PSI in car_data" do
      described_class.record_endpoint(vehicle_state: {
        tpms_pressure_fl: 3.0, tpms_pressure_fr: 3.1,
        tpms_pressure_rl: 2.95, tpms_pressure_rr: 2.975,
      })

      expect(car_data.dig(:vehicle_state, :tpms_pressure_fl)).to eq(43.5)
      expect(car_data.dig(:vehicle_state, :tpms_pressure_fr)).to eq(45.0)
    end

    it "drops tpms_pressure_* when sensor offline (so readers don't see a stale value)" do
      described_class.record_endpoint(vehicle_state: {
        tpms_pressure_fl: 3.0, tpms_pressure_fr: "<invalid>",
      })

      expect(car_data.dig(:vehicle_state, :tpms_pressure_fl)).to eq(43.5)
      expect(car_data.dig(:vehicle_state)&.key?(:tpms_pressure_fr)).to eq(false)
    end
  end

  describe "Location overlay — trust whatever Tesla sent" do
    it "applies a partial Location (lat only) without clobbering existing lng" do
      described_class.record_endpoint(drive_state: { latitude: 40.0, longitude: -111.0 })
      described_class.record_telemetry(Location: { latitude: 40.5 })

      # The lat that Tesla just reported wins; lng remains from the endpoint.
      expect(car_data.dig(:drive_state, :latitude)).to eq(40.5)
      expect(car_data.dig(:drive_state, :longitude)).to eq(-111.0)
    end

    it "applies a full Location" do
      described_class.record_telemetry(Location: { latitude: 40.5, longitude: -111.5 })

      expect(car_data.dig(:drive_state, :latitude)).to eq(40.5)
      expect(car_data.dig(:drive_state, :longitude)).to eq(-111.5)
    end
  end

  describe "location_name meta" do
    it "sets car_data[:location_name] from the matched contact when one is nearby" do
      contact = double(name: "Home", present?: true)
      allow_any_instance_of(AddressBook).to receive(:find_contact_near).and_return(contact)
      described_class.record_telemetry(Location: { latitude: 40.5, longitude: -111.5 })

      expect(car_data[:location_name]).to eq("Home")
    end

    it "falls back to reverse-geocoded city when no contact is near" do
      allow_any_instance_of(AddressBook).to receive(:find_contact_near).and_return(nil)
      allow_any_instance_of(AddressBook).to receive(:reverse_geocode).and_return("Salt Lake City")
      described_class.record_telemetry(Location: { latitude: 40.7, longitude: -111.9 })

      expect(car_data[:location_name]).to eq("Salt Lake City")
    end
  end
end
