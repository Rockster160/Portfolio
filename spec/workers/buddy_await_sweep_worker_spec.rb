require "rails_helper"

# Every other gate resolves on its own — a countdown finishes, a checklist and a
# form sit in the thread where the person can see them. A relay gate is
# invisible and depends on someone ELSE choosing to reply, so left alone it
# either fires days late or never, and both read as the sequence having quietly
# finished.
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

  it "closes out a question that was never answered" do
    action = gate!(expires_at: 1.minute.ago)

    described_class.new.perform

    expect(action.reload).to be_expired
  end

  # Naming the person, because "nobody answered" is unhelpfully vague in a
  # household of several.
  it "says who didn't answer and what it therefore skipped" do
    gate!(expires_at: 1.minute.ago)

    described_class.new.perform

    expect(convo.byte_messages.last.body).to include("#{partner.first_name} never answered")
  end

  # Everything behind the question was about the answer, so none of it runs.
  it "drops the queue rather than running it late" do
    gate!(expires_at: 1.minute.ago)

    described_class.new.perform

    expect(BuddyRelay.notify.count).to eq(0)
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
