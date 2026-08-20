require "rails_helper"

# Recovery hangs off the relay's check-in rather than a poll, so the trigger is
# "the Mac is definitely alive" — but the check-in only proves OUTBOUND reach.
# Everything here turns on gating the actual recovery on the inbound probe.
RSpec.describe TeslaProxyRecoveryWorker do
  let(:control) { instance_double(TeslaControl, refresh: true) }

  before do
    allow(DataStorage).to receive(:[]).and_call_original
    allow(DataStorage).to receive(:[]=).and_call_original
    allow(DataStorage).to receive(:[]).with(:tesla_proxy_unreachable).and_return(true)
    allow(DataStorage).to receive(:[]).with(:local_ip).and_return("97.117.17.133")
    allow(TeslaSwitch).to receive(:disabled?).and_return(false)
    allow(ProxyRequest).to receive(:probe).and_return({ ok: true })
    allow(TeslaControl).to receive(:me).and_return(control)
    allow(SlackNotifier).to receive(:notify)
    allow(TeslaCommand).to receive(:proxy_unreachable!)
  end

  it "clears the flag and refreshes the token once the probe passes" do
    described_class.new.perform

    expect(TeslaCommand).to have_received(:proxy_unreachable!).with(false)
    expect(control).to have_received(:refresh)
    expect(SlackNotifier).to have_received(:notify).with(/recovered/)
  end

  # The check-in that triggers this travels OUTBOUND, so it says nothing about
  # whether prod can get back in — which is the half that was broken.
  it "does nothing while the inbound probe still fails" do
    allow(ProxyRequest).to receive(:probe).and_return({ ok: false, failed_at: :tcp })

    described_class.new.perform

    expect(TeslaCommand).not_to have_received(:proxy_unreachable!)
    expect(control).not_to have_received(:refresh)
  end

  it "does nothing when prod never thought the proxy was down" do
    allow(DataStorage).to receive(:[]).with(:tesla_proxy_unreachable).and_return(false)

    described_class.new.perform

    expect(ProxyRequest).not_to have_received(:probe)
    expect(control).not_to have_received(:refresh)
  end

  # Muting Tesla is a deliberate act. Recovery firing every check-in would both
  # fight that decision and re-trigger the muted-reminder path.
  it "stands down while Tesla is muted" do
    allow(TeslaSwitch).to receive(:disabled?).and_return(true)

    described_class.new.perform

    expect(ProxyRequest).not_to have_received(:probe)
    expect(control).not_to have_received(:refresh)
  end

  # The flag means "prod cannot reach the relay". The probe just disproved that,
  # so it stays cleared even if auth is separately broken — otherwise this
  # re-runs on every check-in forever over a problem it cannot fix.
  it "leaves the flag cleared and stays quiet when the refresh itself fails" do
    allow(control).to receive(:refresh).and_raise(RestClient::Unauthorized)

    expect { described_class.new.perform }.not_to raise_error

    expect(TeslaCommand).to have_received(:proxy_unreachable!).with(false)
    expect(SlackNotifier).not_to have_received(:notify)
  end
end
