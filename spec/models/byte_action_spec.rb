require "rails_helper"

RSpec.describe ByteAction, type: :model do
  let(:user)  { User.me }
  let(:convo) { user.byte_conversations.create!(name: "test", mode: :claude) }

  it "auto-generates a request_id and expires_at on create" do
    action = described_class.create!(
      user: user, byte_conversation: convo, kind: :permission, buttons: [],
    )
    expect(action.request_id).to be_present
    expect(action.expires_at).to be_within(5.seconds).of(described_class::DEFAULT_TTL.from_now)
  end

  it "apply_decision! flips state and updates the linked message metadata" do
    action = described_class.create_request!(
      user: user, conversation: convo, kind: :permission,
      title: "Bash", subtitle: "ls -la",
      buttons: [{ label: "Allow", value: "allow" }, { label: "Deny", value: "deny" }],
    )
    expect(action.pending?).to eq(true)
    action.apply_decision!(value: "allow")
    expect(action.reload.decided?).to eq(true)
    expect(action.decision["value"]).to eq("allow")
    expect(action.byte_message.reload.metadata["action_state"]).to eq("decided")
  end

  it "apply_decision! is idempotent once decided" do
    action = described_class.create_request!(
      user: user, conversation: convo, kind: :permission, buttons: [{ label: "Ok", value: "ok" }],
    )
    action.apply_decision!(value: "ok")
    first_decided_at = action.reload.decided_at
    # second decision should be a no-op
    action.apply_decision!(value: "different")
    expect(action.reload.decision["value"]).to eq("ok")
    expect(action.reload.decided_at).to be_within(1.second).of(first_decided_at)
  end

  it "create_request! also creates a linked action-request message" do
    action = described_class.create_request!(
      user: user, conversation: convo, kind: :question,
      title: "Which?", subtitle: "pick one",
      buttons: [{ label: "A", value: "a" }, { label: "B", value: "b" }],
      multi_select: true,
    )
    msg = action.byte_message
    expect(msg).to be_present
    expect(msg.metadata["kind"]).to eq("action-request")
    expect(msg.metadata["action_kind"]).to eq("question")
    expect(msg.metadata["multi_select"]).to eq(true)
    expect(msg.metadata["buttons"].size).to eq(2)
  end

  it "active scope excludes decided and expired" do
    live    = described_class.create_request!(user: user, conversation: convo, kind: :permission, buttons: [])
    decided = described_class.create_request!(user: user, conversation: convo, kind: :permission, buttons: [])
    decided.apply_decision!(value: "x")
    expired = described_class.create!(
      user: user, byte_conversation: convo, kind: :permission, buttons: [],
      expires_at: 1.minute.ago,
    )
    expect(described_class.active).to include(live)
    expect(described_class.active).not_to include(decided)
    expect(described_class.active).not_to include(expired)
  end
end
