require "rails_helper"

# Verifies TeslaControl entry points short-circuit when TeslaSwitch is muted,
# and that the previously-silent PROXY_UNREACHABLE_ERRORS branch now posts a
# tailored Slack message via the classifier when the switch is on.
RSpec.describe TeslaControl do
  let(:user) { User.me }
  let(:ctrl) { TeslaControl.new(user) }

  before do
    user.caches.set(TeslaSwitch::CACHE_KEY, {})
    allow(SlackNotifier).to receive(:notify)
    allow(TeslaCommand).to receive(:broadcast)
  end

  context "when switch is muted" do
    before { TeslaSwitch.disable!(reason: "spec") }

    it "proxy_command does not hit the API" do
      expect(ctrl.api).not_to receive(:proxy_post)
      expect(ctrl.send(:proxy_command, :flash_lights)).to be(false)
    end

    it "command does not hit the API" do
      expect(ctrl.api).not_to receive(:post)
      expect(ctrl.send(:command, :navigation_request, {})).to be(false)
    end

    it "wake_up returns false without calling the API" do
      expect(ctrl.api).not_to receive(:proxy_post)
      expect(ctrl.wake_up).to be(false)
    end

    it "vehicle_data returns cached data without hitting the API" do
      expect(ctrl.api).not_to receive(:get)
      ctrl.vehicle_data
    end

    it "posts the once-per-day muted reminder on a blocked attempt" do
      ctrl.send(:proxy_command, :flash_lights)
      expect(SlackNotifier).to have_received(:notify).with(/Tesla is muted/)
    end
  end

  context "when switch is enabled but proxy is unreachable" do
    it "wakeup_retry posts a proxy_unreachable Slack message via err()" do
      allow(ctrl).to receive(:perform_requests?).and_return(true)
      allow(ctrl).to receive(:proxy_post_vehicle).and_raise(Errno::EHOSTUNREACH)
      ctrl.send(:proxy_command, :flash_lights)
      expect(SlackNotifier).to have_received(:notify).with(/home Mac proxies/)
    end
  end
end
