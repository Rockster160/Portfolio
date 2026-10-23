require "rails_helper"

# Device state, a window of the day, and several conditions at once: "if the
# garage is open, it's after ten and I'm not home".
RSpec.describe ScheduleCondition do
  let(:user) { create(:user) } # Denver, as everyone is

  def device(name, state)
    allow(Buddy::DeviceStates).to receive(:find).and_call_original
    allow(Buddy::DeviceStates).to receive(:find).with(user, name).and_return({ device: name, state: state })
  end

  describe "a device" do
    it "goes ahead when the device reports that state" do
      device("Garage Door", "open")

      expect(described_class.met?({ device: "Garage Door", state: "open" }, user: user)).to be(true)
    end

    it "holds back when it reports another" do
      device("Garage Door", "close")

      expect(described_class.met?({ device: "Garage Door", state: "open" }, user: user)).to be(false)
    end

    # Sensors report the bare verb; people say the adjective.
    it "reads closed as close" do
      device("Garage Door", "close")

      expect(described_class.met?({ device: "Garage Door", state: "closed" }, user: user)).to be(true)
    end

    it "takes the other polarity" do
      device("Porch Light", "on")

      expect(described_class.met?({ device: "Porch Light", state: "on", expect: :is_not }, user: user)).to be(false)
    end

    it "can't be answered for a device that never reports" do
      allow(Buddy::DeviceStates).to receive(:find).and_return(nil)

      expect { described_class.met?({ device: "Moat", state: "full" }, user: user) }.to raise_error(/no device/)
    end

    it "refuses one with no state to compare" do
      expect { described_class.normalize({ device: "Garage Door" }) }.to raise_error(/needs the state/)
    end
  end

  describe "a time of day" do
    def at(clock, &block)
      travel_to(Time.find_zone("America/Denver").parse("2026-10-23 #{clock}"), &block) # a Friday
    end

    it "is inside a plain window" do
      at("15:00") { expect(described_class.met?({ after: "14:00", before: "16:00" }, user: user)).to be(true) }
      at("16:30") { expect(described_class.met?({ after: "14:00", before: "16:00" }, user: user)).to be(false) }
    end

    it "runs a window that ends before it starts over midnight" do
      night = { after: "10pm", before: "6am" }
      at("23:30") { expect(described_class.met?(night, user: user)).to be(true) }
      at("05:00") { expect(described_class.met?(night, user: user)).to be(true) }
      at("12:00") { expect(described_class.met?(night, user: user)).to be(false) }
    end

    it "reads the day in their zone" do
      at("21:00") {
        expect(described_class.met?({ days: "weekdays" }, user: user)).to be(true)
        expect(described_class.met?({ days: "sat,sun" }, user: user)).to be(false)
      }
    end

    it "refuses a time it can't read" do
      expect { described_class.normalize({ after: "teatime" }) }.to raise_error(/time of day/)
    end
  end

  describe "several at once" do
    let(:rule) {
      described_class.from_rows(
        JSON.generate([{ device: "Garage Door", state: "open" }, { after: "22:00", before: "06:00" }]),
      )
    }

    it "needs every one" do
      device("Garage Door", "open")

      travel_to(Time.find_zone("America/Denver").parse("2026-10-23 23:00")) {
        expect(described_class.met?(rule, user: user)).to be(true)
      }
      travel_to(Time.find_zone("America/Denver").parse("2026-10-23 15:00")) {
        expect(described_class.met?(rule, user: user)).to be(false)
      }
    end

    it "takes any one when asked to" do
      device("Garage Door", "close")
      either = described_class.from_rows(
        [{ device: "Garage Door", state: "open" }, { after: "22:00", before: "06:00" }],
        match: :any,
      )

      travel_to(Time.find_zone("America/Denver").parse("2026-10-23 23:00")) {
        expect(described_class.met?(either, user: user)).to be(true)
      }
    end

    # The answerable part settles it; only a deciding unknown raises.
    it "says no at 3pm whatever the sensor is doing" do
      allow(Buddy::DeviceStates).to receive(:find).and_return(nil)

      travel_to(Time.find_zone("America/Denver").parse("2026-10-23 15:00")) {
        expect(described_class.met?(rule, user: user)).to be(false)
      }
      travel_to(Time.find_zone("America/Denver").parse("2026-10-23 23:00")) {
        expect { described_class.met?(rule, user: user) }.to raise_error(/no device/)
      }
    end

    it "stores a group of one as that one" do
      expect(described_class.from_rows([{ after: "22:00" }])).to eq(kind: :time, after: "22:00", expect: :inside)
    end

    it "is no condition at all when the list is empty" do
      expect(described_class.from_rows("[]")).to be_nil
    end

    it "folds in a single check given the older way" do
      combined = described_class.from_rows([{ after: "22:00" }], also: { kind: :location, place: "home", expect: :away })

      expect(combined[:kind]).to eq(:all)
      expect(combined[:of].pluck(:kind)).to contain_exactly(:location, :time)
    end

    it "reads back as one sentence" do
      expect(described_class.describe(rule)).to eq("only if Garage Door is open and it's after 10pm and before 6am")
    end

    it "round-trips through a jsonb column" do
      stored = JSON.parse(rule.to_json)

      expect(described_class.normalize(stored)).to eq(described_class.normalize(rule))
    end

    it "checks a device exists when it's set" do
      allow(Buddy::DeviceStates).to receive(:find).and_return(nil)

      expect { described_class.validate!(rule, user) }.to raise_error(/no device called "Garage Door"/)
    end
  end
end
