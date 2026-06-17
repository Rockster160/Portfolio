require "rails_helper"

# Locks in two related fixes:
# 1. Fleet Telemetry wraps records as { data: {...}, metadata: {...}, msg: ... }.
#    `TeslaTelemetry.process` used to read the outer level for field names
#    and silently no-op on every push.
# 2. Absent / zero-valued telemetry fields used to overwrite cached real
#    values, triggering false-positive Chores alerts (e.g. all four tires
#    reported low because pressures came in as 0).
RSpec.describe TeslaTelemetry do
  let(:user)  { User.me }
  let(:cache) { user.caches.find_or_create_by!(key: :car_data) }

  before do
    cache.data = {}
    cache.save!
    user.caches.find_or_create_by!(key: :tesla_endpoint).update!(data: {})
    user.caches.find_or_create_by!(key: :tesla_telemetry).update!(data: {})
    allow(::TeslaCommand).to receive(:broadcast)
    # The Jil triggers fire on real state changes and aren't what these specs
    # are exercising. Stubbing the methods that call ::Jil.trigger avoids
    # Ruby-3 hash-vs-kwarg verifying-mock conflicts.
    allow_any_instance_of(described_class).to receive(:detect_drive_changes)
    allow_any_instance_of(described_class).to receive(:detect_charge_changes)
    allow_any_instance_of(described_class).to receive(:fire_general_trigger)
  end

  # Seeds the endpoint cache's `current` with a prior good poll result.
  # Mirrors how vehicle_data polling gets its data into TeslaCacheStore.
  def seed_endpoint(snapshot)
    user.caches.set(:tesla_endpoint, { current: snapshot, history: [] })
  end

  def process(payload)
    described_class.process(payload)
    user.caches.find_by(key: :car_data).data.with_indifferent_access
  end

  describe "envelope unwrapping" do
    it "reads from the inner :data hash when given Fleet Telemetry's record_payload shape" do
      result = process({
        data:     { ChargeState: "Charging" },
        metadata: { vin: "TEST_VIN", txtype: "V" },
        msg:      "record_payload",
      })

      expect(result.dig("charge_state", "charging_state")).to eq("Charging")
    end

    it "still handles a flat hash (older callers / tests)" do
      result = process(ChargeState: "Idle")
      expect(result.dig("charge_state", "charging_state")).to eq("Idle")
    end
  end

  describe "absent values" do
    it "does not overwrite a known-good charging state with an empty wrapper" do
      seed_endpoint(charge_state: { charging_state: "Charging" })

      result = process({ data: { ChargeState: {} } })

      expect(result.dig("charge_state", "charging_state")).to eq("Charging")
    end

    it "applies a partial Location (lat only) without clobbering the existing lng" do
      seed_endpoint(drive_state: { latitude: 40.0, longitude: -111.0 })

      result = process({ data: { Location: { latitude: 40.5 } } })

      # Trust telemetry: lat updated, lng untouched from the endpoint baseline.
      expect(result.dig("drive_state", "latitude")).to eq(40.5)
      expect(result.dig("drive_state", "longitude")).to eq(-111.0)
    end

    it "drops Tesla's '<invalid>' sentinel rather than corrupting current" do
      seed_endpoint(drive_state: { speed: 35 })

      result = process({ data: { VehicleSpeed: "<invalid>" } })

      expect(result.dig("drive_state", "speed")).to eq(35)
    end
  end

  describe ".pressure_psi" do
    it "converts BAR readings (Tesla's native unit) to PSI" do
      expect(described_class.pressure_psi(3.0)).to eq(43.5)
    end

    it "passes PSI readings through (in case ingest ever stores PSI directly)" do
      expect(described_class.pressure_psi(43.5)).to eq(43.5)
    end

    it "returns nil for missing / zero / negative readings" do
      [nil, 0, -1, 0.0].each { |v| expect(described_class.pressure_psi(v)).to be_nil }
    end
  end

  describe "#check_tire_pressure with realistic BAR readings" do
    let(:chores) { instance_double("List", add: nil, remove: nil) }
    before { allow(user).to receive(:list_by_name).with(:Chores).and_return(chores) }

    it "does NOT add chore items when all tires are healthy 3.0 BAR (43.5 PSI)" do
      seed_endpoint(vehicle_state: {
        tpms_pressure_fl: 3.0, tpms_pressure_fr: 3.1,
        tpms_pressure_rl: 2.95, tpms_pressure_rr: 2.975,
      })

      process({ data: { ChargeState: "Idle" } })

      expect(chores).not_to have_received(:add)
    end
  end

  describe "#check_tire_pressure" do
    let(:chores) { instance_double("List", add: nil, remove: nil) }

    before { allow(user).to receive(:list_by_name).with(:Chores).and_return(chores) }

    it "does not flag tires when all readings are 0 (sensor offline)" do
      seed_endpoint(vehicle_state: {
        tpms_pressure_fl: 0, tpms_pressure_fr: 0,
        tpms_pressure_rl: 0, tpms_pressure_rr: 0,
      })

      process({ data: { ChargeState: "Idle" } })

      expect(chores).not_to have_received(:add)
    end

    it "flags only the genuinely low tire when others read valid pressures" do
      seed_endpoint(vehicle_state: {
        tpms_pressure_fl: 41.0, tpms_pressure_fr: 41.5,
        tpms_pressure_rl: 35.0, tpms_pressure_rr: 42.0,
      })

      process({ data: { ChargeState: "Idle" } })

      expect(chores).to have_received(:add).with("Back Left tire pressure low")
      expect(chores).not_to have_received(:add).with(/Front (Left|Right)/)
      expect(chores).not_to have_received(:add).with(/Back Right/)
    end
  end

  # The drive-change detection is one of the few hot paths that fires a
  # Jil trigger directly. Locks the explicit-hash form so Ruby 3's
  # keyword-arg separation doesn't bind `speed:` to the method's `auth:`
  # / `auth_id:` kwargs and re-raise the `unknown keyword: :speed`
  # webhook error.
  describe "#detect_drive_changes — Jil trigger passes data as an explicit hash" do
    let(:tel) {
      instance = described_class.allocate
      instance.instance_variable_set(:@user, user)
      instance.instance_variable_set(:@data, { VehicleSpeed: 35 })
      instance.instance_variable_set(:@car_data, { drive_state: { speed: 35 } })
      instance.instance_variable_set(:@prev_speed, 0)
      instance
    }

    before do
      # Outer top-level `before` stubs detect_drive_changes (so other
      # tests don't fire jil triggers) — un-stub it for this case.
      allow_any_instance_of(described_class).to receive(:detect_drive_changes).and_call_original
    end

    it "fires :tesla_drive_start with the speed hash without ArgumentError" do
      received = []
      # Intercept the lower-level Executor.trigger so Ruby still runs
      # Jil.trigger's real dispatch — that's where the kwarg-vs-hash
      # binding bug would surface.
      allow(::Jil::Executor).to receive(:trigger) { |*args, **kwargs| received << [args, kwargs]; [] }
      expect { tel.send(:detect_drive_changes) }.not_to raise_error
      args, _kwargs = received.first
      expect(args[0..2]).to eq([user, :tesla_drive_start, { speed: 35 }])
    end
  end
end
