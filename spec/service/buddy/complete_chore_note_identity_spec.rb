require "rails_helper"

# Prod 2440: "Log 2 water as Hint Raspberry and then 3 water without a note"
# created only the 2 noted waters — the 3 un-noted ones collapsed into a
# duplicate of the first call (note was in VOLATILE_ARGS + missing from the
# merge_key), while the reply claimed all 5 went in.
RSpec.describe "Buddy complete_chore note identity (prod 2440)" do
  let(:user)   { FactoryBot.create(:user) }
  let!(:chore) { FactoryBot.create(:chore, name: "8oz Water", created_by_user: user) }
  let!(:convo) {
    user.byte_conversations.create!(
      mode: :buddy, name: "Buddy", last_message_at: Time.current, buddy_theme: "byte",
    )
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  def run(rounds)
    inbound = convo.byte_messages.create!(
      user: user, direction: :outbound, state: :sent,
      body: "Log 2 water as Hint Raspberry and then 3 water without a note",
    )
    Buddy::GPT::Turn.run!(inbound, client: FakeBuddyClient.new(rounds))
  end

  it "keeps the two note-differing batches distinct: 2 noted + 3 un-noted" do
    run([
      { tool_calls: [{ name: :complete_chore, arguments: { "chore" => "8oz Water", "count" => 2, "note" => "Hint Raspberry" } }] },
      { tool_calls: [{ name: :complete_chore, arguments: { "chore" => "8oz Water", "count" => 3 } }] },
      { text: "Both batches are in." },
    ])

    completions = chore.chore_completions
    expect(completions.count).to eq(5)
    expect(completions.where(note: "Hint Raspberry").count).to eq(2)
    expect(completions.where(note: [nil, ""]).count).to eq(3)
  end

  it "still count-merges identical (same-note) repeats in one round" do
    captured = nil
    allow(Buddy::ProposalBuilder).to receive(:create) { |args|
      captured = args[:markers]
      { action: nil, auto_ran: true, forms: [] }
    }

    run([
      {
        tool_calls: [
          { name: :complete_chore, call_id: "a", arguments: { "chore" => "8oz Water" } },
          { name: :complete_chore, call_id: "b", arguments: { "chore" => "8oz Water" } },
        ],
      },
      { text: "Two waters." },
    ])

    # Two identical calls survive as markers; ProposalBuilder collapses them into
    # one count-2 row (unchanged behavior).
    expect(captured.length).to eq(2)
  end
end
