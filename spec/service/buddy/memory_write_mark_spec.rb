require "rails_helper"

# `remember` and `forget` are silent tools: nothing about them reaches the
# prose, which is deliberate — a companion narrating its own bookkeeping is a
# companion spending the conversation on itself. But silent is not the same as
# invisible, and somebody's long-term record changing with no sign at all leaves
# them no way to catch it when it's wrong.
#
# So a turn that wrote to memory carries a mark, and the bubble wears a small
# brain in the corner.
RSpec.describe "Buddy memory-write mark" do
  let(:user)   { create(:user) }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  around { |ex| Sidekiq::Testing.fake! { ex.run } }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    convo.update_columns(buddy_theme: "byte")
  }

  def reply_to(text, calls: [])
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "hey")
    rounds  = calls.any? ? [{ tool_calls: calls }, { text: text }] : [{ text: text }]
    Buddy::GPT::Turn.run!(inbound, client: FakeBuddyClient.new(rounds))
    convo.byte_messages.where(direction: :inbound).order(:id).last
  end

  it "marks a turn that wrote a memory" do
    reply = reply_to("Got it.", calls: [
      { name: :remember, call_id: "c1", arguments: { "fact" => "Their dog is called Byte." } },
    ])

    expect(reply.metadata["kept"]).to be(true)
  end

  it "marks a turn that pruned one" do
    user.buddy_memories.create!(kind: :preference, content: "Their dog is called Fae.", severity: 0)

    reply = reply_to("Dropped that.", calls: [
      { name: :forget, call_id: "c1", arguments: { "match" => "Fae" } },
    ])

    expect(reply.metadata["kept"]).to be(true)
  end

  # The overwhelming majority of turns. A mark on every reply would say nothing.
  it "leaves an ordinary reply unmarked" do
    expect(reply_to("Morning!").metadata["kept"]).to be_nil
  end

  # Setting a face is not a change to what is held about them.
  it "does not mark a turn that only changed the expression" do
    reply = reply_to("Aw.", calls: [
      { name: :set_mood, call_id: "c1", arguments: { "expression" => "sad" } },
    ])

    expect(reply.metadata["kept"]).to be_nil
  end

  # A thread note is how ONE conversation behaves, not what is held about the
  # person, so it stays unmarked too.
  it "does not mark a note scoped to the thread" do
    reply = reply_to("Sure.", calls: [
      { name: :add_note, call_id: "c1", arguments: { "fact" => "Keep this thread strictly work." } },
    ])

    expect(reply.metadata["kept"]).to be_nil
  end
end
