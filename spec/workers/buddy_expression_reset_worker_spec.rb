require "rails_helper"

# The mood is persistent by design — nothing drifts it mid-conversation, because
# a face changing unprompted reads as a glitch. This worker only handles the
# leftover case: an expression still sitting there long after the exchange that
# set it ended.
RSpec.describe BuddyExpressionResetWorker do
  let(:user) { create(:user) }

  before { allow(MonitorChannel).to receive(:broadcast_to) }

  def buddy_convo(expression:, last_message_at:)
    convo = user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: last_message_at)
    convo.update_column(:buddy_expression, expression)
    convo
  end

  # Resetting writes with update_column so it doesn't bump activity and re-arm
  # itself on the next sweep.
  it "rests a face left behind by a quiet conversation, tells the client, and leaves activity alone" do
    convo = buddy_convo(expression: "happy", last_message_at: 10.minutes.ago)
    was = convo.last_message_at

    described_class.new.perform

    expect(convo.reload.buddy_expression).to eq("neutral")
    expect(convo.last_message_at).to be_within(1.second).of(was)
    expect(MonitorChannel).to have_received(:broadcast_to).with(
      user,
      hash_including(data: hash_including(kind: :buddy_expression, expression: "neutral", transient: false)),
    )
  end

  it "leaves a live conversation's face exactly where it is" do
    convo = buddy_convo(expression: "happy", last_message_at: 1.minute.ago)

    described_class.new.perform

    expect(convo.reload.buddy_expression).to eq("happy")
  end

  it "does not reach across the boundary a moment early" do
    convo = buddy_convo(expression: "sad", last_message_at: (described_class::IDLE_AFTER - 30.seconds).ago)

    described_class.new.perform

    expect(convo.reload.buddy_expression).to eq("sad")
  end

  it "says nothing about a face already resting" do
    buddy_convo(expression: "neutral", last_message_at: 10.minutes.ago)

    described_class.new.perform

    expect(MonitorChannel).not_to have_received(:broadcast_to)
  end

  it "leaves non-Buddy conversations alone" do
    convo = user.byte_conversations.create!(mode: :claude, name: "claude", last_message_at: 10.minutes.ago)
    convo.update_column(:buddy_expression, "happy")

    described_class.new.perform

    expect(convo.reload.buddy_expression).to eq("happy")
  end
end
