require "rails_helper"

# The three confidence levels: level 1 fires + receipt chip (no checkbox),
# level 2 fires immediately as a PRE-CHECKED undoable row, level 3 waits for a
# tap. This covers level 2 (the new behavior) and the level-2/3 split.
RSpec.describe "Buddy proposal levels" do
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let!(:message) {
    convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "hi", metadata: { "kind" => "buddy" })
  }

  before do
    user.update!(chore_household_id: household.id)
    allow(MonitorChannel).to receive(:broadcast_to)
  end

  def build(markers)
    Buddy::ProposalBuilder.create(user: user, byte_message: message.reload, markers: markers)
  end

  it "runs a level-2 tool immediately and marks the row executed + undoable" do
    result = build([{ tool_name: :log_event, payload: { name: "Coffee" } }])
    btn = result[:action].buttons.first

    expect(btn["status"]).to eq("executed")
    expect(btn["undoable"]).to be(true)
    expect(ActionEvent.where(user: user, name: "Coffee")).to exist
  end

  it "undoes a level-2 row when it's unchecked" do
    action = build([{ tool_name: :log_event, payload: { name: "Tea" } }])[:action]
    id = action.buttons.first["id"]

    Buddy::ProposalExecutor.undo!(action.id, id)

    expect(action.reload.buttons.first["status"]).to eq("undone")
    expect(ActionEvent.where(user: user, name: "Tea")).not_to exist
  end

  it "executes level-2 rows but leaves level-3 rows pending in the same checklist" do
    result = build([
      { tool_name: :log_event,    payload: { name: "Water" } },  # level 2
      { tool_name: :create_chore, payload: { name: "Dust shelves" } }, # level 3
    ])
    by_tool = result[:action].buttons.index_by { |b| b["tool_name"] }

    expect(by_tool["log_event"]["status"]).to eq("executed")
    expect(by_tool["create_chore"]["status"]).to eq("pending")
    # The level-3 chore was NOT created yet — it waits for a tap.
    expect(Chore.where(name: "Dust shelves")).not_to exist
  end

  it "tiers are assigned as expected on the registry" do
    expect(Buddy::Tools[:log_event][:level]).to eq(2)
    expect(Buddy::Tools[:complete_chore][:level]).to eq(2)
    expect(Buddy::Tools[:add_list_item][:level]).to eq(2)
    expect(Buddy::Tools[:call_jil_function][:level]).to eq(1)
    expect(Buddy::Tools[:call_jil_function][:auto]).to be(true)
    expect(Buddy::Tools[:create_chore][:level]).to eq(3)
  end
end
