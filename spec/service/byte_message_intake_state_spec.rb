require "rails_helper"

# What the SENDER's own bubble says about their message.
#
# It used to be posted `pending` and flipped to `sent` by TurnDispatcher, which
# is when the worker picks it up — so "…" meant "a Sidekiq job hasn't started",
# and the HTTP response to the send carried that stale snapshot. Whichever of
# the two routes landed second won, the websocket usually got there first, and
# the echo then repainted the bubble back to sending. It stayed there: nothing
# broadcasts that message again. Byte would be mid-reply above a message still
# showing as pending.
RSpec.describe ByteMessageIntake do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(BuddyDeliverWorker).to receive(:perform_async)
  end

  def send!(body)
    described_class.call(user: user, conversation: convo, body: body)
  end

  it "counts as sent the moment the server has it" do
    expect(send!("what's on my agenda?")).to be_sent
  end

  it "still hands the turn to Buddy" do
    message = send!("what's on my agenda?")

    expect(BuddyDeliverWorker).to have_received(:perform_async).with(message.id)
  end

  # The order the client needs: their bubble settles first, and the pet starts
  # thinking after, as its own separate signal.
  it "confirms the message before it says Buddy is thinking" do
    seen = []
    allow(MonitorChannel).to receive(:broadcast_to) { |_u, payload|
      seen << (payload.dig(:data, :kind) == :message ? :message : :other)
    }
    allow(Buddy::ExpressionState).to receive(:transition!) { seen << :thinking }

    send!("hello")

    expect(seen.first).to eq(:message)
    expect(seen).to include(:thinking)
  end

  # The one case where it legitimately isn't going anywhere yet.
  it "says queued instead when Buddy is asleep" do
    allow(Buddy::SleepGuard).to receive(:sleeping?).and_return(true)

    expect(send!("hello")).to be_queued
    expect(BuddyDeliverWorker).not_to have_received(:perform_async)
  end

  describe "the turn that follows" do
    it "leaves an already-sent message alone rather than repainting it" do
      message = send!("hello")
      allow(Buddy::GPT::Turn).to receive(:run!).and_return(true)
      allow(Buddy::Compactor).to receive(:should_compact?).and_return(false)

      expect(MonitorChannel).not_to receive(:broadcast_to)
      Buddy::TurnDispatcher.deliver!(message)
    end

    # BuddyWakeWorker hands a drained message back as `pending`, so the flip
    # still has to happen for that one.
    it "still settles one that came back out of the sleep queue" do
      message = send!("hello")
      message.update!(state: :pending)
      allow(Buddy::GPT::Turn).to receive(:run!).and_return(true)
      allow(Buddy::Compactor).to receive(:should_compact?).and_return(false)

      Buddy::TurnDispatcher.deliver!(message)

      expect(message.reload).to be_sent
    end
  end
end
