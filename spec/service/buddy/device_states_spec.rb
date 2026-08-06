require "rails_helper"

# The house's own state, off the Home Assistant cache.
#
# The gap this closes produced confident wrong answers: asked whether the
# laundry gate was open, the only route was a live Jil function, and when none
# happened to exist the reply was "I can't check that from here" — which was
# false, because the state was sitting in a cache the whole time.
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

  describe "who can see it" do
    it "is the owner's cache, readable by the whole household" do
      housemate = create(:user, chore_household_id: owner.chore_household_id)

      expect(described_class.available?(owner)).to be(true)
      expect(described_class.available?(housemate)).to be(true)
    end

    # It describes the house they live in, not his private data — but somebody
    # outside the house has no business in it.
    it "is not readable by somebody outside the household" do
      outsider = create(:user)

      expect(described_class.available?(outsider)).to be(false)
      expect(described_class.for_user(outsider)).to be_empty
    end
  end

  describe ".for_user" do
    it "reports each sensor with its state" do
      rows = described_class.for_user(owner, now: now)

      gate = rows.detect { |r| r[:device] == "Laundry Gate" }
      expect(gate[:state]).to eq("open")
      expect(gate[:battery]).to eq(100)
    end

    # A four-hour-old reading dressed as a current one is how "the gate is
    # shut" becomes a lie.
    it "carries how old every reading is" do
      rows = described_class.for_user(owner, now: now)

      expect(rows.detect { |r| r[:device] == "Doggy Sensor" }[:ago]).to eq("just now")
      expect(rows.detect { |r| r[:device] == "Laundry Gate" }[:ago]).to eq("45 min ago")
      expect(rows.detect { |r| r[:device] == "Doorbell" }[:ago]).to eq("5h ago")
    end

    it "marks anything past the stale window" do
      rows = described_class.for_user(owner, now: now)

      expect(rows.detect { |r| r[:device] == "Doggy Sensor" }[:stale]).to be(false)
      expect(rows.detect { |r| r[:device] == "Doorbell" }[:stale]).to be(true)
    end

    it "survives a malformed cache rather than taking the turn down" do
      cache!({ "Broken" => "not a hash", "Fine" => sensor("open", 60) })

      rows = described_class.for_user(owner, now: now)

      expect(rows.pluck(:device)).to eq(["Fine"])
    end

    it "is empty rather than raising when nothing has ever been cached" do
      owner.caches.set(described_class::KEY, {})

      expect(described_class.for_user(owner, now: now)).to be_empty
    end
  end

  describe ".find" do
    it "finds a device by its own name, case-insensitively" do
      expect(described_class.find(owner, "laundry gate")[:state]).to eq("open")
    end

    it "finds one by a fragment of the name" do
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

  describe "the context section" do
    it "reaches the model through get_context" do
      convo = owner.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)

      section = Buddy::Context.full(owner, convo)[:device_states]

      expect(section.pluck(:device)).to include("Laundry Gate")
      expect(Buddy::GPT::ContextTool::SECTIONS).to include(:device_states)
    end

    it "tells the model to look here before claiming it can't see something" do
      prompt = Buddy::Personality.for(owner, conversation: owner.byte_conversations.create!(mode: :buddy))

      expect(prompt).to include("**`device_states`**")
      expect(prompt).to include("Request this FIRST for any question about the state of something physical")
      expect(prompt).to include("Say how old the reading is whenever it isn't fresh")
    end
  end
end
