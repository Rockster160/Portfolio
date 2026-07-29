require "rails_helper"

# Integration-style smoke over the whole Buddy pipeline as it actually runs in
# production: a user message goes through Buddy::GPT::Turn (with a fake client
# standing in for OpenAI), the model's tool calls become a checkbox action, the
# user taps one row, and Buddy::ProposalExecutor does the tool-side work.
#
# No HTTP and no network — the client seam is injected.
RSpec.describe "Buddy end-to-end" do
  let(:user)  { FactoryBot.create(:user) }
  let(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy") }

  before do
    allow(WebPushNotifications).to receive(:send_to_byte)

    @side_effects = []
    side_effects  = @side_effects
    Buddy::Tools.register(
      name:        :e2e_log,
      description: "spec-only",
      args:        { name: { type: :string, required: true } },
      confirm:     ->(p, _) { { summary: "Log #{p[:name]}?", resolved: {} } },
      label:       ->(p, _) { p[:name].to_s },
      merge_key:   ->(p) { "e2e_log:#{p[:name]}" },
      merge_label: ->(p, n) { "#{n}× #{p[:name]}" },
      execute:     ->(p, _) {
        side_effects << p[:name]
        { name: p[:name] }
      },
      receipt:     ->(r, _) { "Logged #{r[:name]}" },
    )
  end

  def user_says(text)
    convo.byte_messages.create!(
      user: user, direction: :outbound, state: :sent, body: text,
    )
  end

  it "turns tool calls into a checkbox action and executes only checked rows" do
    # The model replies with prose plus three calls: Coffee twice (which merge
    # on merge_key) and Walk once.
    client = FakeBuddyClient.new([
      {
        text:       "You did a lot today.",
        tool_calls: [
          { name: :e2e_log, arguments: { "name" => "Coffee" } },
          { name: :e2e_log, arguments: { "name" => "Coffee" } },
          { name: :e2e_log, arguments: { "name" => "Walk" } },
        ],
      },
    ])

    Buddy::GPT::Turn.run!(user_says("busy day"), client: client)

    reply = convo.byte_messages.where(direction: :inbound).order(:created_at).last
    expect(reply.body).to eq("You did a lot today.")
    expect(reply.state).to eq("delivered")

    action = ByteAction.find_by(byte_message_id: reply.id)
    expect(action.buttons.length).to eq(2)

    coffee_row = action.buttons.find { |b| b["label"].include?("Coffee") }
    walk_row   = action.buttons.find { |b| b["label"].include?("Walk") }
    expect(coffee_row["count"]).to eq(2)
    expect(walk_row["count"]).to eq(1)

    # User taps only the Coffee row.
    action.apply_decision!(value: [coffee_row["id"]])
    Buddy::ProposalExecutor.perform(action.id)

    # Coffee executed twice (count=2), Walk was left unchecked → cancelled.
    expect(@side_effects).to eq(["Coffee", "Coffee"])
    action.reload
    expect(action.buttons.find { |b| b["id"] == coffee_row["id"] }["status"]).to eq("executed")
    expect(action.buttons.find { |b| b["id"] == walk_row["id"] }["status"]).to eq("cancelled")

    receipts = convo.byte_messages.where("metadata->>'kind' = 'buddy_receipt'")
    expect(receipts.count).to eq(1)
    expect(receipts.first.body).to include("Coffee")
  end

  it "fires a silent tool immediately and keeps it out of the visible reply" do
    client = FakeBuddyClient.new([
      {
        text:       "Oof, that's rough.",
        tool_calls: [{ name: :set_mood, arguments: { "expression" => "sad" } }],
      },
    ])

    Buddy::GPT::Turn.run!(user_says("today was hard"), client: client)

    expect(convo.reload.buddy_expression).to eq("sad")
    reply = convo.byte_messages.where(direction: :inbound).order(:created_at).last
    expect(reply.body).to eq("Oof, that's rough.")
    expect(ByteAction.find_by(byte_message_id: reply.id)).to be_nil
  end

  it "reads context and answers in the same reply" do
    client = FakeBuddyClient.new([
      { text: "One sec.", tool_calls: [{ name: :get_context, arguments: { "sections" => ["chores_all"] } }] },
      { text: "Nothing left on your list." },
    ])

    Buddy::GPT::Turn.run!(user_says("what's left today?"), client: client)

    reply = convo.byte_messages.where(direction: :inbound).order(:created_at).last
    expect(reply.body).to eq("One sec.\n\nNothing left on your list.")

    # Second round carried the first round's prose plus the call and its output,
    # or the model would repeat its own placeholder.
    second = client.calls.last.input
    expect(second.pluck(:type)).to include(:function_call, :function_call_output)
    expect(second.any? { |i| i[:role] == :assistant && i[:content] == "One sec." }).to be(true)
  end

  it "falls back to an honest body when every tool call is discarded" do
    client = FakeBuddyClient.new([
      { text: "", tool_calls: [{ name: :nonexistent_tool, arguments: { "foo" => "bar" } }] },
    ])

    Buddy::GPT::Turn.run!(user_says("do the thing"), client: client)

    reply = convo.byte_messages.where(direction: :inbound).order(:created_at).last
    expect(reply.body).to match(/couldn't quite line that one up/i)
  end

  it "marks the reply failed when the model errors" do
    client = FakeBuddyClient.new([{ error: "rate limited" }])

    Buddy::GPT::Turn.run!(user_says("hi"), client: client)

    reply = convo.byte_messages.where(direction: :inbound).order(:created_at).last
    expect(reply.state).to eq("failed")
    expect(reply.body).to include("rate limited")
  end
end
