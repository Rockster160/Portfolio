require "rails_helper"

RSpec.describe ByteConversation, type: :model do
  let(:user) { User.me }

  it "assigns a default conversation to messages that don't specify one" do
    msg = user.byte_messages.create!(body: "hi")
    expect(msg.byte_conversation).to be_present
    expect(msg.byte_conversation.user_id).to eq(user.id)
  end

  it "returns a stable default per-user across calls" do
    a = ByteConversation.default_for(user)
    b = ByteConversation.default_for(user)
    expect(a.id).to eq(b.id)
  end

  it "exposes mode as an integer-backed enum" do
    convo = user.byte_conversations.create!(name: "shell fun", mode: :bash)
    expect(convo.mode).to eq("bash")
    expect(convo.bash?).to eq(true)
  end

  it "bumps last_message_at when a message is created" do
    convo = user.byte_conversations.create!(name: "chat", mode: :claude)
    expect(convo.last_message_at).to be_nil
    convo.byte_messages.create!(user: user, body: "yo", direction: :inbound, state: :delivered)
    convo.reload
    expect(convo.last_message_at).to be_present
  end

  it "orders active conversations by most-recent activity" do
    older = user.byte_conversations.create!(name: "older", mode: :claude, last_message_at: 2.hours.ago)
    newer = user.byte_conversations.create!(name: "newer", mode: :claude, last_message_at: 5.minutes.ago)
    expect(user.byte_conversations.active.ordered.map(&:id).first(2)).to eq([newer.id, older.id])
  end

  it "excludes archived conversations from the active scope" do
    live     = user.byte_conversations.create!(name: "live",     mode: :claude)
    archived = user.byte_conversations.create!(name: "archived", mode: :claude, archived: true)
    expect(user.byte_conversations.active).to include(live)
    expect(user.byte_conversations.active).not_to include(archived)
  end

  it "returns a mode-derived display name when unnamed" do
    convo = user.byte_conversations.create!(mode: :bash)
    expect(convo.display_name).to eq("Terminal")
  end
end
