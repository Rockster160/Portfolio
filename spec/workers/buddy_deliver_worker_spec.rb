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
end
