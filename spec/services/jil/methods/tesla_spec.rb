require "rails_helper"

# Covers the notification-pairing contract on Jil::Methods::Tesla: every
# command that broadcasts to the car also fires a user-facing
# PushNotification via WebPushNotifications.send_to. Drift here means the
# car can be acting on commands the user has no log of.
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
    # Default: car is not at the destination — individual specs override
    # when they need the already-at branch. Without this, the wrapper
    # hits AddressBook#geocode → Google Maps unstubbed.
    allow(::TripState).to receive(:car_at?).and_return(false)
    allow(::TripState).to receive(:car_navigating_to?).and_return(false)
    allow(::TripState).to receive(:start_for_destination!)
    %i[start_car off_car honk set_temp navigate add_stop doors windows pop_frunk pop_boot defrost heat_driver heat_passenger send].each do |m|
      allow(control).to receive(m).and_return(true)
    end
    # Avoid rspec-mocks ruby3 hash-as-kwargs partial-double snag on
    # `send_to(user, payload, channel:)`: stub the underlying push_sub
    # check and capture payloads via a side-effecting receiver.
    @push_payloads = []
    push_payloads = @push_payloads
    allow(::WebPushNotifications).to receive(:send_to) { |_u, payload, **_kw| push_payloads << payload; true }
  end

  def expect_notify(title_matcher, body_matcher=nil)
    expect(@push_payloads.any? { |p|
      p[:tag] == :tesla_action &&
        title_matcher === p[:title] &&
        (body_matcher.nil? || body_matcher === p[:body])
    }).to be(true),
      "expected a notification title=#{title_matcher.inspect} body=#{body_matcher.inspect}; got #{@push_payloads.inspect}"
  end

  it "notifies on navigate with the destination in the body" do
    expect(tesla.navigate("Costco")).to be(true)
    expect_notify("Navigating", "Costco")
  end

  it "calls TripState.start_for_destination! on every navigate" do
    allow(::TripState).to receive(:start_for_destination!)
    tesla.navigate("Costco")
    expect(::TripState).to have_received(:start_for_destination!).with("Costco", user)
  end

  it "notifies on stop, honk, flashLights, lock/unlock, windows, frunk/trunk, defrost, seat heat" do
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

    expect(@push_payloads.size).to eq(12)
  end

  it "notifies on setTemp with the temperature in the body" do
    tesla.setTemp(72)
    expect_notify("Temperature set", "72°F")
  end

  it "notifies on start with a summary of selected options in the body" do
    tesla.start([{ temp: 70, heatDriver: true }, { vent: true }])
    expect_notify("Climate on", match(/70°F.+driver seat.+vent/))
  end

  it "notifies on start with a title-only message when no options" do
    tesla.start(nil)
    expect_notify("Climate on", nil)
  end

  it "notifies on addStop success with the destination in the body" do
    allow(control).to receive(:add_stop).and_return(true)
    expect(tesla.addStop("Lowes")).to be(true)
    expect_notify("Stop added", "Lowes")
  end

  it "notifies on addStop failure with a different title" do
    allow(control).to receive(:add_stop).and_return(false)
    expect(tesla.addStop("nonsense location")).to be(false)
    expect_notify("Couldn't add stop", "nonsense location")
  end

  it "carries no leading emoji in any tag" do
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
    @push_payloads.each do |p|
      expect(p[:title]).not_to match(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]/),
        "unexpected emoji in title #{p[:title].inspect}"
    end
  end

  it "skips the broadcast (and notification) when TeslaSwitch is disabled" do
    allow(::TeslaSwitch).to receive(:disabled?).and_return(true)
    allow(::TeslaSwitch).to receive(:maybe_remind_muted!)
    expect(tesla.navigate("Costco")).to be(false)
    expect(@push_payloads).to be_empty
  end

  it "skips the broadcast for a non-me user" do
    allow(user).to receive(:me?).and_return(false)
    expect(tesla.navigate("Costco")).to be(false)
    expect(@push_payloads).to be_empty
  end

  describe "already-at destination" do
    it "on navigate: skips TeslaControl and notifies 'Already at destination' when car is at destination" do
      allow(::TripState).to receive(:car_at?).with("Costco", user: user).and_return(true)
      expect(control).not_to receive(:navigate)
      expect(tesla.navigate("Costco")).to be(true)
      expect_notify("Already at destination", "Costco")
    end

    it "on start with navigate: skips start_car AND navigate when car is at destination" do
      allow(::TripState).to receive(:car_at?).with("Costco", user: user).and_return(true)
      expect(control).not_to receive(:start_car)
      expect(control).not_to receive(:navigate)
      expect(tesla.start([{ navigate: "Costco" }])).to be(true)
      expect_notify("Already at destination", "Costco")
    end

    it "on start without navigate: does NOT consult TripState (no destination to compare)" do
      expect(::TripState).not_to receive(:car_at?)
      tesla.start([{ temp: 70 }])
      expect_notify("Climate on", match(/70°F/))
    end

    it "on start: runs the full flow when car is NOT at destination" do
      allow(::TripState).to receive(:car_at?).with("Costco", user: user).and_return(false)
      expect(control).to receive(:start_car)
      expect(control).to receive(:navigate).with("Costco")
      tesla.start([{ navigate: "Costco" }])
    end
  end

  describe "already-navigating-there destination" do
    it "on navigate: skips TeslaControl and notifies 'Already navigating there' when trip is en route" do
      allow(::TripState).to receive(:car_navigating_to?).with("Costco", user: user).and_return(true)
      expect(control).not_to receive(:navigate)
      expect(tesla.navigate("Costco")).to be(true)
      expect_notify("Already navigating there", "Costco")
    end

    it "on start with navigate: skips start_car AND navigate when trip is en route" do
      allow(::TripState).to receive(:car_navigating_to?).with("Costco", user: user).and_return(true)
      expect(control).not_to receive(:start_car)
      expect(control).not_to receive(:navigate)
      expect(tesla.start([{ navigate: "Costco" }])).to be(true)
      expect_notify("Already navigating there", "Costco")
    end

    it "car_at? takes precedence over car_navigating_to? when both are true" do
      allow(::TripState).to receive(:car_at?).with("Costco", user: user).and_return(true)
      allow(::TripState).to receive(:car_navigating_to?).with("Costco", user: user).and_return(true)
      tesla.navigate("Costco")
      expect_notify("Already at destination", "Costco")
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
    before { allow(::TripState).to receive(:car_at?).and_return(false) }

    it "uses caller-provided title + body instead of the default 'Climate on · …'" do
      tesla.start([{ navigate: "Costco", title: "Starting Car", body: "10m drive to Costco" }])
      payload = @push_payloads.last
      expect(payload[:title]).to eq("Starting Car")
      expect(payload[:body]).to eq("10m drive to Costco")
    end

    it "supports title-only (body optional)" do
      tesla.start([{ title: "Starting car" }])
      payload = @push_payloads.last
      expect(payload[:title]).to eq("Starting car")
      expect(payload).not_to have_key(:body)
    end
  end

  describe "silent" do
    before { allow(::TripState).to receive(:car_at?).and_return(false) }

    it "runs the car commands but suppresses the notification" do
      expect(control).to receive(:start_car)
      expect(control).to receive(:navigate).with("Costco")
      tesla.start([{ navigate: "Costco", silent: true }])
      expect(@push_payloads).to be_empty
    end

    it "suppresses even the 'Already at' notification (guest-mode caller opted out)" do
      allow(::TripState).to receive(:car_at?).with("Costco", user: user).and_return(true)
      tesla.start([{ navigate: "Costco", silent: true }])
      expect(@push_payloads).to be_empty
    end
  end
end
