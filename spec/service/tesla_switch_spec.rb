require "rails_helper"

RSpec.describe TeslaSwitch do
  let(:user) { User.me }

  before do
    user.caches.set(TeslaSwitch::CACHE_KEY, {})
    allow(SlackNotifier).to receive(:notify)
  end

  it "starts enabled when cache is empty" do
    expect(TeslaSwitch).to be_enabled
    expect(TeslaSwitch).not_to be_disabled
  end

  it "disable! persists across module-function calls and is reflected by enabled?" do
    TeslaSwitch.disable!(reason: "Traveling")
    expect(TeslaSwitch).to be_disabled
    expect(TeslaSwitch.reason).to eq("Traveling")
    expect(TeslaSwitch.disabled_at).to be_within(2.seconds).of(Time.current)
  end

  it "enable! clears the muted reminder so the next mute notifies again" do
    TeslaSwitch.disable!
    TeslaSwitch.maybe_remind_muted!(:test)
    expect(SlackNotifier).to have_received(:notify).once
    TeslaSwitch.enable!
    TeslaSwitch.disable!
    TeslaSwitch.maybe_remind_muted!(:test)
    expect(SlackNotifier).to have_received(:notify).twice
  end

  it "maybe_remind_muted! only posts once per REMINDER_INTERVAL" do
    TeslaSwitch.disable!
    3.times { TeslaSwitch.maybe_remind_muted!(:thing) }
    expect(SlackNotifier).to have_received(:notify).once
  end

  it "maybe_remind_muted! is a no-op when enabled" do
    TeslaSwitch.maybe_remind_muted!(:thing)
    expect(SlackNotifier).not_to have_received(:notify)
  end

  it "toggle_link points at the production host in prod" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    expect(TeslaSwitch.toggle_link(:enable)).to include("https://ardesian.com/tesla/switch?to=enable")
  end
end
