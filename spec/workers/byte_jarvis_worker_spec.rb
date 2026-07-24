require "rails_helper"

RSpec.describe ByteJarvisWorker do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(name: "jarv", mode: :jarvis) }
  let(:message) {
    convo.byte_messages.create!(
      user:      user,
      direction: :outbound,
      state:     :pending,
      body:      "turn on the kitchen lights",
    )
  }

  it "posts a Jarvis response back as an inbound message on the same conversation" do
    allow(::Jarvis).to receive(:command).with(user, message.body).and_return("done — kitchen on")

    expect {
      described_class.new.perform(message.id)
    }.to change { convo.byte_messages.inbound.count }.by(1)

    reply = convo.byte_messages.inbound.last
    expect(reply.body).to eq("done — kitchen on")
    expect(reply.state).to eq("delivered")
    expect(reply.metadata["kind"]).to eq("jarvis")
    expect(reply.metadata["in_reply_to"]).to eq(message.id)
  end

  it "flips a pending outbound to sent so the composer's spinner clears" do
    allow(::Jarvis).to receive(:command).and_return("k")
    described_class.new.perform(message.id)
    expect(message.reload.state).to eq("sent")
  end

  it "handles Jarvis raising by surfacing a failed system message" do
    allow(::Jarvis).to receive(:command).and_raise(StandardError, "boom")

    expect {
      described_class.new.perform(message.id)
    }.to change { convo.byte_messages.inbound.count }.by(1)

    err = convo.byte_messages.inbound.last
    expect(err.state).to eq("failed")
    expect(err.body).to include("Jarvis error")
    expect(err.metadata["error"]).to eq(true)
  end

  it "is a no-op for a missing message id" do
    expect { described_class.new.perform(-1) }.not_to raise_error
  end
end
