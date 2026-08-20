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

    described_class.new.perform(message.id)
    expect(message.reload.state).to eq("sent")
  end

  it "flips a claude turn to failed when the Mac is unreachable" do
    message = build_message(:claude)
    allow(ByteLocal).to receive(:deliver).and_return(nil)
    allow(MonitorChannel).to receive(:broadcast_to)

    described_class.new.perform(message.id)
    expect(message.reload.state).to eq("failed")
  end

  it "is a no-op for a missing message id" do
    expect(Buddy::TurnDispatcher).not_to receive(:deliver!)
    expect { described_class.new.perform(-1) }.not_to raise_error
  end

  # The `:failed` state was meant to be the whole signal, and it isn't one for a
  # message that renders nowhere. The daily audit's prompt is hidden, so when
  # its handoff failed on 20 Aug the state landed on an invisible row and the
  # first sign of it was somebody noticing no report had come.
  describe "when the Mac doesn't take it" do
    before {
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(Buddy::Errors).to receive(:report)
    }

    it "says so, rather than only setting a state nobody sees" do
      message = build_message(:claude)
      allow(ByteLocal).to receive(:deliver).and_return(nil)

      described_class.new.perform(message.id)

      expect(Buddy::Errors).to have_received(:report).with(
        hash_including(section: "byte.local_handoff", user: message.user),
      )
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

    it "notes whether the message was one the person could see" do
      message = build_message(:claude)
      message.update!(metadata: { "hidden" => true })
      allow(ByteLocal).to receive(:deliver).and_return(nil)

      described_class.new.perform(message.id)

      expect(Buddy::Errors).to have_received(:report).with(
        hash_including(extra: hash_including(hidden: true, message_id: message.id)),
      )
    end

    it "still broadcasts the failed state" do
      message = build_message(:claude)
      allow(ByteLocal).to receive(:deliver).and_return(nil)

      described_class.new.perform(message.id)

      expect(MonitorChannel).to have_received(:broadcast_to)
    end

    it "says nothing when it went through" do
      message = build_message(:claude)
      ok = instance_double(Net::HTTPOK)
      allow(ok).to receive(:is_a?).with(Net::HTTPSuccess).and_return(true)
      allow(ByteLocal).to receive(:deliver).and_return(ok)

      described_class.new.perform(message.id)

      expect(Buddy::Errors).not_to have_received(:report)
    end
  end
end
