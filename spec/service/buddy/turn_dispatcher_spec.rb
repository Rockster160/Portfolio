require "rails_helper"

RSpec.describe Buddy::TurnDispatcher do
  let(:user) { User.me }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }
  let(:message) {
    convo.byte_messages.create!(user: user, direction: :outbound, state: :pending, body: "hi")
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::Compactor).to receive(:should_compact?).and_return(nil)
    allow(Buddy::GPT::Turn).to receive(:run!).and_return(true)
  end

  it "marks the inbound message sent and runs the turn" do
    expect(described_class.deliver!(message)).to be(true)

    expect(message.reload).to be_sent
    expect(Buddy::GPT::Turn).to have_received(:run!).with(message)
  end

  it "compacts first when the conversation has grown enough" do
    allow(Buddy::Compactor).to receive(:should_compact?).and_return(:hard)
    allow(Buddy::Compactor).to receive(:compact!)

    described_class.deliver!(message)

    expect(Buddy::Compactor).to have_received(:compact!).with(convo).ordered
    expect(Buddy::GPT::Turn).to have_received(:run!).ordered
  end

  it "marks the message failed when the turn blows up" do
    allow(Buddy::GPT::Turn).to receive(:run!).and_raise("boom")

    expect(described_class.deliver!(message)).to be(false)
    expect(message.reload).to be_failed
  end

  describe "per-conversation serialization" do
    # The Mac used to serialize turns with a per-conversation mutex. Buddy now
    # runs in Rails with one Sidekiq job per turn, so the dispatcher has to
    # re-establish it — otherwise a follow-up turn seeded by check_weather (or a
    # person double-sending) builds history while the first turn is mid-reply.
    it "holds a per-conversation advisory lock while the turn runs" do
      held = nil
      allow(Buddy::GPT::Turn).to receive(:run!) {
        held = ByteConversation.advisory_lock_exists?(described_class.lock_name(convo))
        true
      }

      described_class.deliver!(message)

      expect(held).to be(true)
    end

    it "releases the lock afterwards" do
      described_class.deliver!(message)

      expect(ByteConversation.advisory_lock_exists?(described_class.lock_name(convo))).to be(false)
    end

    it "releases the lock even when the turn raises" do
      allow(Buddy::GPT::Turn).to receive(:run!).and_raise("boom")

      described_class.deliver!(message)

      expect(ByteConversation.advisory_lock_exists?(described_class.lock_name(convo))).to be(false)
    end

    it "keys the lock per conversation so two threads never block each other" do
      other = user.byte_conversations.create!(mode: :buddy, name: "Other")

      expect(described_class.lock_name(convo)).not_to eq(described_class.lock_name(other))
    end

    it "still runs the turn if the lock cannot be acquired, rather than dropping it" do
      # A wedged holder must not cost the person their reply.
      allow(ByteConversation).to receive(:with_advisory_lock_result)
        .and_return(instance_double(WithAdvisoryLock::Result, lock_was_acquired?: false, result: nil))

      described_class.deliver!(message)

      expect(Buddy::GPT::Turn).to have_received(:run!).with(message)
      expect(message.reload).to be_sent
    end
  end
end
