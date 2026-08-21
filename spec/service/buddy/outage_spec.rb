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
    it "puts every companion in the house to sleep" do
      expect { described_class.down!(detail: "no credits") }
        .to change { convo.reload.buddy_sleep_until }.from(nil)

      expect(described_class).to be_down
      expect(Buddy::SleepGuard.sleeping?(user)).to be(true)
      expect(Buddy::SleepGuard.reason(user)).to eq(described_class::REASON)
    end

    it "says so in Slack, with the way out attached" do
      described_class.down!(detail: "You have no credits remaining.")

      expect(SlackNotifier).to have_received(:notify) { |msg|
        expect(msg).to include("no credits remaining")
        expect(msg).to include("/slack/action/buddy_retry")
      }
    end

    # One outage, one post. The alternative fills the channel at the rate
    # people keep typing.
    it "does not announce a second time while already down" do
      described_class.down!(detail: "first")
      described_class.down!(detail: "second")

      expect(SlackNotifier).to have_received(:notify).once
    end

    it "schedules no wake, because there is no time to wake at" do
      expect { described_class.down!(detail: "x") }.not_to(change { BuddyWakeWorker.jobs.size })
    end
  end

  describe ".retry!" do
    it "wakes the house when the account answers" do
      described_class.down!(detail: "x")
      allow_any_instance_of(Buddy::GPT::Client).to receive(:ping).and_return({ ok: true, error: nil })

      expect(described_class.retry!).to include("Back up")
      expect(described_class).not_to be_down
      expect(convo.reload.buddy_sleep_until).to be_nil
      expect(convo.metadata).not_to have_key("sleep_reason")
    end

    it "stays down, and says what it said, when the account still refuses" do
      described_class.down!(detail: "x")
      allow_any_instance_of(Buddy::GPT::Client).to receive(:ping)
        .and_return({ ok: false, error: "You have no credits remaining." })

      expect(described_class.retry!).to include("Still down", "no credits")
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
