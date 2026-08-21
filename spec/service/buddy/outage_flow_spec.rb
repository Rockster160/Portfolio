require "rails_helper"

# The whole arc: a turn dies on an account-level failure, the house goes to
# sleep, what anyone sends next fails visibly instead of queueing, and a retry
# is what brings it back.
RSpec.describe "Buddy sleeping through a GPT outage" do
  let(:user) { User.me }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(SlackNotifier).to receive(:notify)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(WebPushNotifications).to receive(:update_count)
    Buddy::Outage.clear!
    # The fake queue is shared across the whole run, so "did this dispatch?"
    # only means anything against an empty one.
    BuddyDeliverWorker.clear
  end

  after { Buddy::Outage.clear! }

  # The suite runs Sidekiq inline, so a dispatched turn would make a real call.
  around { |example| Sidekiq::Testing.fake! { example.run } }

  def send!(body)
    ByteMessageIntake.call(user: user, conversation: convo, body: body)
  end

  def user_says(body)
    convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
  end

  describe "a turn that dies on the account" do
    it "sleeps the house" do
      client = FakeBuddyClient.new([{ error: "You have no credits remaining.", error_kind: :outage }])

      Buddy::GPT::Turn.run!(user_says("hi"), client: client)

      expect(Buddy::Outage).to be_down
      expect(Buddy::SleepGuard.sleeping?(user)).to be(true)
    end

    it "leaves the house awake for an ordinary failure" do
      client = FakeBuddyClient.new([{ error: "upstream exploded" }])

      Buddy::GPT::Turn.run!(user_says("hi"), client: client)

      expect(Buddy::Outage).not_to be_down
      expect(Buddy::SleepGuard.sleeping?(user)).to be(false)
    end
  end

  describe "what happens to what you send next" do
    # The difference from a usage cap, and the whole reason the two are told
    # apart: an outage has no end to wait for, so holding it would be a promise
    # nobody can keep.
    it "fails the message rather than queueing it" do
      Buddy::Outage.down!(detail: "no credits")

      message = send!("are you there?")

      expect(message.reload.state).to eq("failed")
      expect(message.metadata["failure"]).to eq(Buddy::Outage::REASON)
      expect(BuddyDeliverWorker.jobs).to be_empty
    end

    it "still QUEUES for a usage cap, which does have an end" do
      Buddy::SleepGuard.sleep_until!(user, 2.hours.from_now)

      message = send!("are you there?")

      expect(message.reload.state).to eq("queued")
    end
  end

  describe "the retry on a failed bubble" do
    it "goes straight back to failed while the provider is still down" do
      Buddy::Outage.down!(detail: "no credits")
      message = send!("are you there?")

      ByteMessageIntake.redispatch!(message.tap { |m| m.update!(state: :pending) })

      expect(message.reload.state).to eq("failed")
    end

    it "goes through once the house is awake again" do
      Buddy::Outage.down!(detail: "no credits")
      message = send!("are you there?")
      allow_any_instance_of(Buddy::GPT::Client).to receive(:ping).and_return({ ok: true, error: nil })
      Buddy::Outage.retry!

      ByteMessageIntake.redispatch!(message.tap { |m| m.update!(state: :pending) })

      expect(message.reload.state).not_to eq("failed")
      expect(BuddyDeliverWorker.jobs.size).to eq(1)
    end
  end
end
