require "rails_helper"

# A relay gate waits on someone ELSE replying, so unlike a countdown or a form
# it never resolves on its own; this sweep expires it.
RSpec.describe BuddyAwaitSweepWorker do
  let(:user)    { create(:user) }
  let(:partner) { create(:user) }
  let!(:convo)  { user.byte_conversations.create!(mode: :buddy, name: "Buddy") }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def message!
    convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok", delivered_at: Time.current)
  end

  def gate!(expires_at:, queue: [{ "kind" => "autos", "calls" => [{ "tool_name" => "message_partner", "payload" => { "to" => "x", "message" => "hi" } }] }])
    relay = BuddyRelay.create!(
      from_user: user, to_user: partner, from_conversation: convo,
      kind: :ask_open, body: "Dinner?", status: :delivered
    )
    ByteAction.create!(
      user:              user,
      byte_conversation: convo,
      byte_message:      message!,
      kind:              :custom,
      tool_name:         Buddy::ProposalBuilder::RELAY_GATE,
      buttons:           [],
      tool_input:        { "deferred" => queue, "relay_id" => relay.id, "var" => "hers" },
      expires_at:        expires_at,
    )
  end

  # Everything behind the question was about the answer, so none of it runs;
  # the person is told who didn't answer.
  it "closes out a question that was never answered, dropping its queue" do
    action = gate!(expires_at: 1.minute.ago)

    described_class.new.perform

    expect(action.reload).to be_expired
    expect(BuddyRelay.notify.count).to eq(0)
    expect(convo.byte_messages.last.body).to include(partner.first_name)
  end

  it "leaves one that's still within its window alone" do
    action = gate!(expires_at: 2.days.from_now)

    described_class.new.perform

    expect(action.reload).to be_pending
  end

  it "says nothing when the gate was holding nothing" do
    gate!(expires_at: 1.minute.ago, queue: [])

    expect { described_class.new.perform }.not_to change(convo.byte_messages, :count)
  end

  # A gate whose queue was already claimed and run is done with; sweeping it
  # again must not announce a failure that didn't happen.
  it "only sweeps gates still pending" do
    action = gate!(expires_at: 1.minute.ago)
    action.update!(state: :decided)

    described_class.new.perform

    expect(convo.byte_messages.pluck(:body)).not_to include(/never answered/)
  end
end
