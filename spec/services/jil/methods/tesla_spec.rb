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

  def expect_notify(title_matcher)
    expect(@push_payloads.any? { |p| title_matcher === p[:title] && p[:tag] == :tesla_action }).to be(true),
      "expected a notification with title matching #{title_matcher.inspect}; got #{@push_payloads.inspect}"
  end

  it "notifies on navigate with the destination" do
    expect(tesla.navigate("Costco")).to be(true)
    expect_notify(match(/Navigating.+Costco/))
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

  it "notifies on setTemp with the temperature" do
    tesla.setTemp(72)
    expect_notify(match(/72°F/))
  end

  it "notifies on start with a summary of selected options" do
    tesla.start([{ temp: 70, heatDriver: true }, { vent: true }])
    expect_notify(match(/Climate on.+70°F.+driver seat.+vent/))
  end

  it "notifies on start with a simple message when no options" do
    tesla.start(nil)
    expect_notify("🚗 Climate on")
  end

  it "notifies on addStop success with the destination" do
    allow(control).to receive(:add_stop).and_return(true)
    expect(tesla.addStop("Lowes")).to be(true)
    expect_notify(match(/Added stop.+Lowes/))
  end

  it "notifies on addStop failure with a different message" do
    allow(control).to receive(:add_stop).and_return(false)
    expect(tesla.addStop("nonsense location")).to be(false)
    expect_notify(match(/Couldn't add stop.+nonsense location/))
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
end
