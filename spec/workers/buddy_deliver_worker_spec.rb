require "rails_helper"

RSpec.describe BuddyDeliverWorker do
  let(:user) { User.me }

  def build_message(mode)
    convo = user.byte_conversations.create!(name: "t", mode: mode)
    convo.byte_messages.create!(
      user:      user,
      direction: :outbound,
      state:     :pending,
      body:      "hi",
    )
  end

  it "routes a buddy turn through TurnDispatcher (the single buddy delivery path)" do
    message = build_message(:buddy)
    expect(Buddy::TurnDispatcher).to receive(:deliver!).with(message)
    described_class.new.perform(message.id)
  end

  it "delivers a claude turn straight to the Mac and flips it to sent on success" do
    message = build_message(:claude)
    allow(ByteLocal).to receive(:deliver).and_return(instance_double(Net::HTTPOK).tap { |r|
      allow(r).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
    })
    allow(MonitorChannel).to receive(:broadcast_to)

    allow(Buddy::Errors).to receive(:report)

    described_class.new.perform(message.id)
    expect(message.reload.state).to eq("sent")
    expect(Buddy::Errors).not_to have_received(:report)
  end

  it "is a no-op for a missing message id" do
    expect(Buddy::TurnDispatcher).not_to receive(:deliver!)
    expect { described_class.new.perform(-1) }.not_to raise_error
  end

  # A `:failed` state alone is invisible for a hidden message, so the handoff
  # failure is reported too.
  describe ".deliver_after_commit" do
    it "waits for the transaction that created the message to commit" do
      allow(described_class).to receive(:perform_async)
      message = nil

      ActiveRecord::Base.transaction do
        message = build_message(:buddy)
        described_class.deliver_after_commit(message.id)
        expect(described_class).not_to have_received(:perform_async)
      end

      expect(described_class).to have_received(:perform_async).with(message.id).once
    end

    it "never enqueues a message that was rolled back" do
      allow(described_class).to receive(:perform_async)

      ActiveRecord::Base.transaction do
        described_class.deliver_after_commit(build_message(:buddy).id)
        raise ActiveRecord::Rollback
      end

      expect(described_class).not_to have_received(:perform_async)
    end
  end

  describe "when the Mac doesn't take it" do
    before {
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(Buddy::Errors).to receive(:report)
    }

    it "flips it to failed, broadcasts that, and reports it with whether it was visible" do
      message = build_message(:claude)
      message.update!(metadata: { "hidden" => true })
      allow(ByteLocal).to receive(:deliver).and_return(nil)

      described_class.new.perform(message.id)

      expect(message.reload.state).to eq("failed")
      expect(MonitorChannel).to have_received(:broadcast_to)
      expect(Buddy::Errors).to have_received(:report).with(
        hash_including(
          section: "byte.local_handoff",
          user:    message.user,
          extra:   hash_including(hidden: true, message_id: message.id),
        ),
      )
    end

    # A shell command to a sleeping laptop otherwise looks like one still running.
    it "says so in the thread, naming the Mac, and pushes it" do
      message = build_message(:bash)
      allow(ByteLocal).to receive(:deliver).and_return(nil)
      allow(ByteNotifier).to receive(:notify)

      described_class.new.perform(message.id)

      note = message.byte_conversation.byte_messages.order(:id).last
      expect(note).not_to eq(message)
      expect(note.body).to include("Couldn't reach the laptop")
      expect(note.metadata).to include("in_reply_to" => message.id, "kind" => "system")
      expect(ByteNotifier).to have_received(:notify).with(message.user, note)
    end

    it "says nothing in the thread for a hidden prompt" do
      message = build_message(:claude)
      message.update!(metadata: { "hidden" => true })
      allow(ByteLocal).to receive(:deliver).and_return(nil)

      expect { described_class.new.perform(message.id) }.not_to change(ByteMessage, :count)
    end

    it "reports a refusal as well as an unreachable Mac" do
      message  = build_message(:claude)
      refusal  = instance_double(Net::HTTPServerError, code: "500")
      allow(refusal).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(ByteLocal).to receive(:deliver).and_return(refusal)

      described_class.new.perform(message.id)

      expect(message.reload.state).to eq("failed")
      expect(Buddy::Errors).to have_received(:report)
    end
  end
end
