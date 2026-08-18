require "rails_helper"

# Covers the announcement contract on Jil::Methods::Tesla: every command that
# broadcasts to the car also says so, via a Jarvis :ws say. Drift here means
# the car can be acting on commands the user has no log of.
RSpec.describe Jil::Methods::Tesla do
  let(:user) { create(:user) }
  let(:control) { double("TeslaControl") }
  let(:jil) { ::Jil::Executor.new(user, "") }
  let(:tesla) { described_class.new(jil) }

  before do
    allow(user).to receive(:me?).and_return(true)
    allow(::TeslaSwitch).to receive(:disabled?).and_return(false)
    allow(::TeslaControl).to receive(:me).and_return(control)
    allow(::PrettyLogger).to receive(:error)
    # Default: car is not at the destination and isn't going anywhere —
    # individual specs override when they need those branches. Without this,
    # the wrapper hits AddressBook#geocode → Google Maps unstubbed.
    allow(::TripState).to receive(:car_at?).and_return(false)
    allow(::TripState).to receive(:car_navigating_to?).and_return(false)
    allow(::TripState).to receive(:car_routing?).and_return(false)
    allow(::TripState).to receive(:start_for_destination!)
    %i[start_car off_car honk set_temp navigate add_stop doors windows pop_frunk pop_boot defrost heat_driver heat_passenger send].each do |m|
      allow(control).to receive(m).and_return(true)
    end
    @says = []
    says = @says
    allow(::Jarvis).to receive(:say) { |msg, *| says << msg }
  end

  def expect_say(matcher)
    expect(@says.any? { |said| matcher === said }).to be(true),
      "expected a say matching #{matcher.inspect}; got #{@says.inspect}"
  end

  it "says the destination and the travel time on navigate" do
    allow(user.address_book).to receive(:traveltime_seconds).with("Costco").and_return(12.minutes.to_i)
    expect(tesla.navigate("Costco")).to be(true)
    expect_say("Navigating to Costco — TT: 12 minutes")
  end

  it "says the destination alone when the travel time is unavailable" do
    allow(user.address_book).to receive(:traveltime_seconds).with("Costco").and_return(nil)
    expect(tesla.navigate("Costco")).to be(true)
    expect_say("Navigating to Costco")
  end

  it "goes out as a Jarvis say — websocket to the dashboard cell, no push" do
    allow(user.address_book).to receive(:traveltime_seconds).and_return(nil)
    tesla.navigate("Costco")
    expect(::Jarvis).to have_received(:say).with("Navigating to Costco")
  end

  # The push is what changed: a car command is either something the person
  # just asked for out loud or automation doing its job, and neither is an
  # interruption worth a buzz.
  it "sends no push notification" do
    allow(::WebPushNotifications).to receive(:send_to)
    allow(user.address_book).to receive(:traveltime_seconds).and_return(nil)
    tesla.navigate("Costco")
    tesla.honk
    expect(::WebPushNotifications).not_to have_received(:send_to)
  end

  it "calls TripState.start_for_destination! on every navigate" do
    allow(::TripState).to receive(:start_for_destination!)
    allow(user.address_book).to receive(:traveltime_seconds).and_return(nil)
    tesla.navigate("Costco")
    expect(::TripState).to have_received(:start_for_destination!).with("Costco", user)
  end

  it "says something on stop, honk, flashLights, lock/unlock, windows, frunk/trunk, defrost, seat heat" do
    tesla.stop
    tesla.honk
    tesla.flashLights
    tesla.lockDoors
    tesla.unlockDoors
    tesla.closeWindows
    tesla.ventWindows
    tesla.popFrunk
    tesla.popTrunk
    tesla.defrost
    tesla.heatDriver
    tesla.heatPassenger

    expect(@says.size).to eq(12)
  end

  it "says the temperature on setTemp" do
    tesla.setTemp(72)
    expect_say("Temperature set to: 72°F")
  end

  it "summarizes the selected options on start" do
    tesla.start([{ temp: 70, heatDriver: true }, { vent: true }])
    expect_say(match(/\AClimate on — .*70°F.+driver seat.+vent/))
  end

  it "says just the headline on start with no options" do
    tesla.start(nil)
    expect_say("Climate on")
  end

  it "says the destination on addStop success" do
    allow(control).to receive(:add_stop).and_return(true)
    expect(tesla.addStop("Lowes")).to be(true)
    expect_say("Stop added — Lowes")
  end

  it "says so differently on addStop failure" do
    allow(control).to receive(:add_stop).and_return(false)
    expect(tesla.addStop("nonsense location")).to be(false)
    expect_say("Couldn't add stop — nonsense location")
  end

  it "stays quiet when TeslaSwitch is disabled" do
    allow(::TeslaSwitch).to receive(:disabled?).and_return(true)
    allow(::TeslaSwitch).to receive(:maybe_remind_muted!)
    expect(tesla.navigate("Costco")).to be(false)
    expect(@says).to be_empty
  end

  it "stays quiet for a non-me user" do
    allow(user).to receive(:me?).and_return(false)
    expect(tesla.navigate("Costco")).to be(false)
    expect(@says).to be_empty
  end

  describe "already-at destination" do
    it "on navigate: skips TeslaControl and says 'Already at destination'" do
      allow(::TripState).to receive(:car_at?).with("Costco", user: user).and_return(true)
      expect(control).not_to receive(:navigate)
      expect(tesla.navigate("Costco")).to be(true)
      expect_say("Already at destination — Costco")
    end

    it "on start with navigate: skips start_car AND navigate" do
      allow(::TripState).to receive(:car_at?).with("Costco", user: user).and_return(true)
      expect(control).not_to receive(:start_car)
      expect(control).not_to receive(:navigate)
      expect(tesla.start([{ navigate: "Costco" }])).to be(true)
      expect_say("Already at destination — Costco")
    end

    it "on start without navigate: does NOT consult TripState (no destination to compare)" do
      expect(::TripState).not_to receive(:car_at?)
      tesla.start([{ temp: 70 }])
      expect_say(match(/\AClimate on — .*70°F/))
    end

    it "on start: runs the full flow when car is NOT at destination" do
      allow(::TripState).to receive(:car_at?).with("Costco", user: user).and_return(false)
      expect(control).to receive(:start_car)
      expect(control).to receive(:navigate).with("Costco")
      tesla.start([{ navigate: "Costco" }])
    end
  end

  describe "already-navigating-there destination" do
    it "on navigate: skips TeslaControl and says 'Already navigating there'" do
      allow(::TripState).to receive(:car_navigating_to?).with("Costco", user: user).and_return(true)
      expect(control).not_to receive(:navigate)
      expect(tesla.navigate("Costco")).to be(true)
      expect_say("Already navigating there — Costco")
    end

    it "on start with navigate: skips start_car AND navigate" do
      allow(::TripState).to receive(:car_navigating_to?).with("Costco", user: user).and_return(true)
      expect(control).not_to receive(:start_car)
      expect(control).not_to receive(:navigate)
      expect(tesla.start([{ navigate: "Costco" }])).to be(true)
      expect_say("Already navigating there — Costco")
    end

    it "car_at? takes precedence over car_navigating_to? when both are true" do
      allow(::TripState).to receive(:car_at?).with("Costco", user: user).and_return(true)
      allow(::TripState).to receive(:car_navigating_to?).with("Costco", user: user).and_return(true)
      tesla.navigate("Costco")
      expect_say("Already at destination — Costco")
    end
  end

  # The car takes ONE destination. A calendar trigger firing mid-drive doesn't
  # add a stop, it replaces where the person is going while they're following
  # it — so a SCHEDULED nav yields, and one they asked for by name doesn't.
  describe "keepRoute" do
    before { allow(::TripState).to receive(:car_routing?).with(user: user).and_return(true) }

    it "leaves a live route alone rather than retargeting the car" do
      expect(control).not_to receive(:start_car)
      expect(control).not_to receive(:navigate)
      expect(tesla.start([{ navigate: "Costco", keepRoute: true }])).to be(true)
      expect_say(match(/Already on a route.+Costco/))
    end

    it "overrides the route when the caller didn't ask to keep it" do
      expect(control).to receive(:navigate).with("Costco")
      tesla.start([{ navigate: "Costco" }])
    end

    it "never blocks a manual navigate, which is the person asking by name" do
      allow(user.address_book).to receive(:traveltime_seconds).and_return(nil)
      expect(control).to receive(:navigate).with("Costco")
      tesla.navigate("Costco")
    end

    it "does not apply without a destination — climate has no route to clobber" do
      expect(control).to receive(:start_car)
      tesla.start([{ temp: 70, keepRoute: true }])
    end

    it "stays out of the way when the car isn't going anywhere" do
      allow(::TripState).to receive(:car_routing?).with(user: user).and_return(false)
      expect(control).to receive(:navigate).with("Costco")
      tesla.start([{ navigate: "Costco", keepRoute: true }])
    end

    # Ordering: being AT the destination is the more specific answer, and the
    # one the person would rather hear.
    it "reports being at the destination ahead of being on a route" do
      allow(::TripState).to receive(:car_at?).with("Costco", user: user).and_return(true)
      tesla.start([{ navigate: "Costco", keepRoute: true }])
      expect_say("Already at destination — Costco")
    end
  end

  describe "#isAt" do
    it "returns true when TripState.car_at? is true" do
      allow(::TripState).to receive(:car_at?).with("Quick Quack", user: user).and_return(true)
      expect(tesla.isAt("Quick Quack")).to be(true)
    end

    it "returns false when TripState.car_at? is false" do
      allow(::TripState).to receive(:car_at?).with("Quick Quack", user: user).and_return(false)
      expect(tesla.isAt("Quick Quack")).to be(false)
    end

    it "swallows errors and returns false" do
      allow(::TripState).to receive(:car_at?).and_raise(StandardError.new("boom"))
      expect(tesla.isAt("Quick Quack")).to be(false)
    end
  end

  describe "title/body override" do
    it "uses caller-provided title + body instead of the default 'Climate on · …'" do
      tesla.start([{ navigate: "Costco", title: "Starting Car", body: "10m drive to Costco" }])
      expect(@says.last).to eq("Starting Car — 10m drive to Costco")
    end

    it "supports title-only (body optional)" do
      tesla.start([{ title: "Starting car" }])
      expect(@says.last).to eq("Starting car")
    end
  end

  describe "silent" do
    it "runs the car commands but says nothing" do
      expect(control).to receive(:start_car)
      expect(control).to receive(:navigate).with("Costco")
      tesla.start([{ navigate: "Costco", silent: true }])
      expect(@says).to be_empty
    end

    it "suppresses even the 'Already at' line (guest-mode caller opted out)" do
      allow(::TripState).to receive(:car_at?).with("Costco", user: user).and_return(true)
      tesla.start([{ navigate: "Costco", silent: true }])
      expect(@says).to be_empty
    end

    it "suppresses the kept-route line too" do
      allow(::TripState).to receive(:car_routing?).with(user: user).and_return(true)
      tesla.start([{ navigate: "Costco", keepRoute: true, silent: true }])
      expect(@says).to be_empty
    end
  end
end
