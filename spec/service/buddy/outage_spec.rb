require "rails_helper"

RSpec.describe Buddy::Outage do
  let(:user) { User.me }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(SlackNotifier).to receive(:notify)
    described_class.clear!
  end

  after { described_class.clear! }

  describe ".down!" do
    # One outage, one post, and no wake scheduled because there is no time to
    # wake at.
    it "sleeps every companion, announces once with the retry route, and schedules no wake", :aggregate_failures do
      wakes = BuddyWakeWorker.jobs.size

      expect {
        described_class.down!(detail: "You have no credits remaining.")
        described_class.down!(detail: "second")
      }.to change { convo.reload.buddy_sleep_until }.from(nil)

      expect(BuddyWakeWorker.jobs.size).to eq(wakes)
      expect(described_class).to be_down
      expect(Buddy::SleepGuard.sleeping?(user)).to be(true)
      expect(Buddy::SleepGuard.reason(user)).to eq(described_class::REASON)
      expect(SlackNotifier).to have_received(:notify).once
      expect(SlackNotifier).to have_received(:notify).with(include("no credits remaining", "/slack/action/buddy_retry"))
    end
  end

  describe ".retry!" do
    before { described_class.down!(detail: "x") }

    it "wakes the house when the account answers", :aggregate_failures do
      allow_any_instance_of(Buddy::GPT::Client).to receive(:ping).and_return({ ok: true, error: nil })

      described_class.retry!

      expect(described_class).not_to be_down
      expect(convo.reload.buddy_sleep_until).to be_nil
      expect(convo.metadata).not_to have_key("sleep_reason")
    end

    it "stays down, passing on what the account said, when it still refuses", :aggregate_failures do
      allow_any_instance_of(Buddy::GPT::Client).to receive(:ping)
        .and_return({ ok: false, error: "You have no credits remaining." })

      expect(described_class.retry!).to include("no credits")
      expect(described_class).to be_down
      expect(Buddy::SleepGuard.sleeping?(user)).to be(true)
    end
  end

  # A usage-cap sleep is somebody else's and must survive this.
  it "leaves a usage-cap sleep alone when it clears" do
    Buddy::SleepGuard.sleep_until!(user, 2.hours.from_now)
    described_class.clear!

    expect(Buddy::SleepGuard.sleeping?(user)).to be(true)
  end
end
