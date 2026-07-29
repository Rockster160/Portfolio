require "rails_helper"

# Tapping an EXPIRED proposal row reissues it as a fresh, tappable checklist on
# a new message — the person never has to re-type the request.
RSpec.describe "Buddy proposal reissue" do
  let(:user) { create(:user) }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo) { user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg) { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  before do
    user.update!(chore_household_id: household.id)
    allow(MonitorChannel).to receive(:broadcast_to)
  end

  it "rebuilds the proposal from a stored button onto a fresh message + action" do
    action = Buddy::ProposalBuilder.create(
      user: user, byte_message: msg,
      markers: [{ tool_name: :create_chore, payload: { name: "Fill Kitty Litter", schedule: "daily" }, span: [0, 0] }]
    )[:action]
    button = action.buttons.first

    expect {
      Buddy::ProposalBuilder.reissue(user: user, conversation: convo, button: button)
    }.to change { ByteAction.where(byte_conversation: convo).count }.by(1)

    fresh = ByteAction.where(byte_conversation: convo).order(:created_at).last
    expect(fresh.id).not_to eq(action.id)
    expect(fresh).to be_pending
    expect(fresh.expires_at).to be > 1.day.from_now                 # a fresh, long window
    expect(fresh.buttons.first["label"]).to eq("Fill Kitty Litter") # same request, re-resolved
    expect(fresh.byte_message.body).to eq("Here you go again:")
  end

  it "degrades to an honest note when the reissued proposal can't rebuild" do
    # An unknown tool → nothing rebuilds.
    ByteAction.where(byte_conversation: convo).count # baseline
    result = Buddy::ProposalBuilder.reissue(
      user: user, conversation: convo,
      button: { "tool_name" => "totally_unknown_tool", "payload" => { "x" => "1" } }
    )

    expect(result[:action]).to be_nil
    note = convo.byte_messages.order(:created_at).last
    expect(note.body).to match(/couldn't set that back up/i)
  end
end
