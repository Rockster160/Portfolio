require "rails_helper"

RSpec.describe "Buddy proposal TTL + label detail" do
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg) { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  before do
    user.update!(chore_household_id: household.id)
    allow(MonitorChannel).to receive(:broadcast_to)
  end

  def build(markers)
    Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
  end

  it "gives a Buddy checklist a long TTL, not the 10-minute default (so a later tap still works)" do
    action = build([{ tool_name: :create_chore, payload: { name: "Water the ficus" }, span: [0, 0] }])[:action]
    expect(action.expires_at).to be > 1.day.from_now
    expect(action).to be_pending
    # And the expiry rides on the message metadata so the client can grey out
    # a stale row instead of letting the person tap into nothing.
    expect(action.byte_message.reload.metadata["action_expires_at"]).to be_present
  end

  it "keeps the destructive timestamp in the sublabel, not the title" do
    ev = ActionEvent.create!(user: user, name: "Coffee", timestamp: Time.zone.local(2026, 7, 28, 15, 10))
    btn = build([{ tool_name: :delete_event, payload: { id: ev.id }, span: [0, 0] }])[:action].buttons.first
    expect(btn["label"]).to eq("Delete Coffee")           # title = no timestamp
    expect(btn["label"]).not_to match(/Jul|:10|PM/)
    expect(btn["sublabel"]).to include("Jul 28")           # timestamp = detail
  end

  it "never renders a blank checkbox label" do
    action = build([{ tool_name: :create_chore, payload: { name: "Water the ficus" }, span: [0, 0] }])[:action]
    expect(action.buttons.first["label"]).to eq("Water the ficus")
    expect(action.buttons.first["label"]).to be_present
  end

  it "shows a full date/time (and notes) on a destructive delete row" do
    ev = ActionEvent.create!(user: user, name: "Strawberry Celsius", notes: "energy drink", timestamp: Time.zone.local(2026, 7, 28, 15, 10))
    action = build([{ tool_name: :delete_event, payload: { id: ev.id }, span: [0, 0] }])[:action]
    btn = action.buttons.first

    expect(btn["label"]).to eq("Delete Strawberry Celsius")
    expect(btn["sublabel"]).to include("Jul 28").and include("energy drink")
  end
end
