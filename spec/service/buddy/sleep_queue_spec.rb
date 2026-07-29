require "rails_helper"

# Queue-while-sleeping: a Buddy turn sent during a usage-cap sleep is held
# (state :queued), cancellable, and drained in order when Buddy wakes.
RSpec.describe "Buddy sleep queue", type: :model do
  let(:user) { User.me }
  # Eager: SleepGuard fans out only across buddy conversations that already
  # exist, so the thread must be present before sleep_until! runs.
  let!(:conversation) { user.byte_conversations.create!(name: :Buddy, mode: :buddy) }

  def http_ok
    Net::HTTPOK.new("1.1", "200", "OK")
  end

  before do
    allow(BuddyWakeWorker).to receive(:perform_at)
    allow(BuddyWakeWorker).to receive(:perform_async)
    allow(MonitorChannel).to receive(:broadcast_to)
  end

  describe "holding while asleep" do
    it "queues a Buddy message instead of dispatching when asleep" do
      Buddy::SleepGuard.sleep_until!(user, 1.hour.from_now)
      msg = conversation.byte_messages.create!(user: user, direction: :outbound, body: "do the dishes")

      expect(ByteLocal).not_to receive(:deliver)
      # simulate the dispatch branch the controller runs
      expect(Buddy::SleepGuard.sleeping?(user)).to be(true)
      msg.update!(state: :queued) if conversation.buddy? && Buddy::SleepGuard.sleeping?(user)

      expect(msg.reload).to be_queued
    end
  end

  describe "waking + draining" do
    it "clears sleep and delivers every queued turn oldest-first" do
      Buddy::SleepGuard.sleep_until!(user, 1.hour.from_now)
      first  = conversation.byte_messages.create!(user: user, direction: :outbound, body: "one", state: :queued)
      second = conversation.byte_messages.create!(user: user, direction: :outbound, body: "two", state: :queued)

      # Force the wake window into the past, then run the worker.
      conversation.update_column(:buddy_sleep_until, 1.minute.ago)
      delivered = []
      allow(ByteLocal).to receive(:deliver) { |m, **| delivered << m.body; http_ok }
      allow(Buddy::Compactor).to receive(:should_compact?).and_return(false)

      BuddyWakeWorker.new.perform(user.id)

      expect(conversation.reload.buddy_sleep_until).to be_nil
      expect(delivered).to eq(%w[one two])
      expect(first.reload).to be_sent
      expect(second.reload).to be_sent
    end

    it "no-ops if the user is still asleep (window extended)" do
      Buddy::SleepGuard.sleep_until!(user, 1.hour.from_now)
      conversation.byte_messages.create!(user: user, direction: :outbound, body: "held", state: :queued)

      expect(ByteLocal).not_to receive(:deliver)
      BuddyWakeWorker.new.perform(user.id)
    end
  end

  describe "maybe_wake!" do
    it "kicks the wake worker once the window has passed" do
      conversation.update_column(:buddy_sleep_until, 1.minute.ago)
      expect(BuddyWakeWorker).to receive(:perform_async).with(user.id)
      Buddy::SleepGuard.maybe_wake!(user)
    end

    it "leaves a still-asleep user alone" do
      conversation.update_column(:buddy_sleep_until, 1.hour.from_now)
      expect(BuddyWakeWorker).not_to receive(:perform_async)
      Buddy::SleepGuard.maybe_wake!(user)
    end
  end
end
