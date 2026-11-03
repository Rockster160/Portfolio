require "rails_helper"

# The house's own state, off the Home Assistant cache.
RSpec.describe Buddy::DeviceStates do
  let(:owner) { User.me }
  let(:now)   { Time.zone.parse("2026-08-06 10:00:00 -0600") }

  def cache!(hash)
    owner.caches.set(described_class::KEY, hash)
  end

  # Mirrors the real payload shape, epoch stamps included.
  def sensor(state, ago_seconds, battery: nil)
    { "state" => state, "at" => (now - ago_seconds).to_f }.tap { |h| h["battery"] = battery if battery }
  end

  before do
    cache!({
      "Doggy Sensor" => sensor("close", 60, battery: 100),
      "Laundry Gate" => sensor("open", 45 * 60, battery: 100),
      "Doorbell"     => sensor("person", 5 * 3_600),
    })
  end

  it "is the owner's cache, readable by the household and nobody outside it", :aggregate_failures do
    housemate = create(:user, chore_household_id: owner.chore_household_id)
    outsider  = create(:user)

    expect(described_class.available?(owner)).to be(true)
    expect(described_class.available?(housemate)).to be(true)
    expect(described_class.available?(outsider)).to be(false)
    expect(described_class.for_user(outsider)).to be_empty
  end

  describe ".for_user" do
    it "reports each sensor's state, battery, age and staleness", :aggregate_failures do
      rows = described_class.for_user(owner, now: now).index_by { |r| r[:device] }

      expect(rows["Laundry Gate"]).to include(state: "open", battery: 100, ago: "45 min ago")
      expect(rows["Doggy Sensor"]).to include(ago: "just now", stale: false)
      expect(rows["Doorbell"]).to include(ago: "5h ago", stale: true)
    end

    it "survives a malformed cache rather than taking the turn down" do
      cache!({ "Broken" => "not a hash", "Fine" => sensor("open", 60) })

      rows = described_class.for_user(owner, now: now)

      expect(rows.pluck(:device)).to eq(["Fine"])
    end

    # The `hass` row for a thermostat only says which stream spoke last; the
    # temperature lives in its own cache. Without it the only thermostat thing
    # in reach was the function that SETS one.
    it "reports each thermostat zone from its own cache, in place of the bare hass row" do
      cache!({ "Main Thermostat" => sensor("temperature", 60) })
      owner.caches.set(described_class::THERMOSTAT_KEY, {
        main: {
          temp:     65,
          humidity: 46,
          mode:     "cool",
          setpoint: 68,
          action:   "idle",
          fan:      false,
          at:       (now - 60).to_i,
        },
      })

      rows = described_class.for_user(owner, now: now)
      main = rows.select { |r| r[:device] == "Main Thermostat" }

      expect(main.length).to eq(1)
      expect(main.first).to include(
        state: "65°F", humidity: 46, mode: "cool", setpoint: 68, running: "idle",
        ago: "just now", stale: false
      )
    end

    it "is empty rather than raising when nothing has ever been cached" do
      owner.caches.set(described_class::KEY, {})

      expect(described_class.for_user(owner, now: now)).to be_empty
    end
  end

  describe ".find" do
    it "finds a device by its name case-insensitively, or by a fragment of it" do
      expect(described_class.find(owner, "laundry gate")[:state]).to eq("open")
      expect(described_class.find(owner, "doggy")[:device]).to eq("Doggy Sensor")
    end

    # "The doggy door" is not what the sensor is called, and the glossary is
    # where the household's own words already live.
    it "follows a device alias from the household glossary" do
      HouseholdGlossaryTerm.create!(
        chore_household: owner.chore_household,
        term: "The doggy door", meaning: "Doggy Sensor",
        aliases: ["dog door", "puppy door"], kind: :device
      )

      expect(described_class.find(owner, "the doggy door")[:device]).to eq("Doggy Sensor")
      expect(described_class.find(owner, "puppy door")[:device]).to eq("Doggy Sensor")
    end

    it "is nil for a device that has never reported" do
      expect(described_class.find(owner, "hot tub")).to be_nil
    end
  end

  it "reaches the model through the full context" do
    convo = owner.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

    section = Buddy::Context.full(owner, convo)[:device_states]

    expect(section.pluck(:device)).to include("Laundry Gate")
  end
end
