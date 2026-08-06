require "rails_helper"

# Byte finds an event by scoped search (even one not logged through him), then
# removes it as an execute-immediately + undoable (Level 2) action.
RSpec.describe "Buddy event search + delete" do
  let(:user)   { create(:user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(Buddy::CompanionDelivery).to receive(:deliver_prompt)
  end

  def build(markers)
    Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
  end

  def search(payload)
    Buddy::GPT::Turn.resolve_tool(
      Buddy::Tools[:search_events],
      { call_id: "call_1", name: :search_events, arguments: payload },
      user: user, conversation: convo,
    )
  end

  it "search_events hands the matching events, with ids, back in the same turn" do
    ActionEvent.create!(user: user, name: "Strawberry Celsius", timestamp: 2.days.ago)
    ActionEvent.create!(user: user, name: "Coffee", timestamp: 1.day.ago)

    result = search(query: "celsius")

    expect(result[:status]).to eq(:answered)
    expect(result[:events].join("\n")).to include("Strawberry Celsius")
    expect(result[:how]).to include("`delete_event`")
    expect(Buddy::CompanionDelivery).not_to have_received(:deliver_prompt)
  end

  # The guidance used to teach `[[propose: delete_event id=N]]`. Markers are
  # retired — Turn strips a stray one and logs it — so that instruction cost a
  # turn and left the event sitting there. Nothing that talks to the model may
  # teach it.
  it "search_events does not teach the retired marker protocol" do
    ActionEvent.create!(user: user, name: "Strawberry Celsius", timestamp: 2.days.ago)

    expect(search(query: "celsius")[:how]).not_to include("[[propose:")
  end

  it "delete_event by id is Level 2 - removes immediately, undoable, and restores on undo" do
    ev = ActionEvent.create!(user: user, name: "Strawberry Celsius", notes: "oops", timestamp: 2.days.ago)

    result = build([{ tool_name: :delete_event, payload: { id: ev.id }, span: [0, 0] }])
    btn = result[:action].buttons.first

    expect(btn["status"]).to eq("executed")   # fired immediately
    expect(btn["undoable"]).to be(true)        # pre-checked, uncheck-to-undo
    expect(ActionEvent.where(id: ev.id)).not_to exist

    Buddy::ProposalExecutor.undo!(result[:action].id, btn["id"])
    expect(ActionEvent.where(user: user, name: "Strawberry Celsius")).to exist # restored
  end

  it "registers delete_event at level 2" do
    expect(Buddy::Tools[:delete_event][:level]).to eq(2)
  end
end
