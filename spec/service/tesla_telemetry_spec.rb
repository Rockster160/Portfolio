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
    allow(::TeslaCommand).to receive(:broadcast)
    # The Jil triggers fire on real state changes and aren't what these specs
    # are exercising. Stubbing the methods that call ::Jil.trigger avoids
    # Ruby-3 hash-vs-kwarg verifying-mock conflicts.
    allow_any_instance_of(described_class).to receive(:detect_drive_changes)
    allow_any_instance_of(described_class).to receive(:detect_charge_changes)
    allow_any_instance_of(described_class).to receive(:fire_general_trigger)
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
    it "does not overwrite cached values with nil / empty wrappers" do
      cache.data = { "charge_state" => { "charging_state" => "Charging" } }
      cache.save!

      process({ data: { ChargeState: {} } })

      result = user.caches.find_by(key: :car_data).data.with_indifferent_access
      expect(result.dig("charge_state", "charging_state")).to eq("Charging")
    end

    it "ignores a partial Location reading (lat only, no lng)" do
      cache.data = { "drive_state" => { "latitude" => 40.0, "longitude" => -111.0 } }
      cache.save!

      process({ data: { Location: { latitude: 40.5 } } })

      result = user.caches.find_by(key: :car_data).data.with_indifferent_access
      expect(result.dig("drive_state", "latitude")).to eq(40.0)
      expect(result.dig("drive_state", "longitude")).to eq(-111.0)
    end
  end

  describe "#check_tire_pressure" do
    let(:chores) { instance_double("List", add: nil, remove: nil) }

    before { allow(user).to receive(:list_by_name).with(:Chores).and_return(chores) }

    it "does not flag tires when all readings are 0 (sensor offline)" do
      cache.data = {
        "vehicle_state" => {
          "tpms_pressure_fl" => 0, "tpms_pressure_fr" => 0,
          "tpms_pressure_rl" => 0, "tpms_pressure_rr" => 0,
        },
      }
      cache.save!

      process({ data: { ChargeState: "Idle" } })

      expect(chores).not_to have_received(:add)
    end

    it "flags only the genuinely low tire when others read valid pressures" do
      cache.data = {
        "vehicle_state" => {
          "tpms_pressure_fl" => 41.0, "tpms_pressure_fr" => 41.5,
          "tpms_pressure_rl" => 35.0, "tpms_pressure_rr" => 42.0,
        },
      }
      cache.save!

      process({ data: { ChargeState: "Idle" } })

      expect(chores).to have_received(:add).with("Back Left tire pressure low")
      expect(chores).not_to have_received(:add).with(/Front (Left|Right)/)
      expect(chores).not_to have_received(:add).with(/Back Right/)
    end
  end
end
