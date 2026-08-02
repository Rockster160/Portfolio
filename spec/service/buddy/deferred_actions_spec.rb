require "rails_helper"

# Consecutive commands: "do X and then tell them" has to happen in that order.
#
# Prod 1201 is the whole reason this exists. "Can you move it to the Ours agenda
# and let Chelsea know?" produced add_agenda_item (level 3, a checkbox) and
# message_partner (level 1, fires on arrival). ProposalBuilder split them purely
# on level, so at 18:02:25 Chelsea was told the event had moved — and the
# checkbox that actually moved it wasn't tapped until 18:02:47. Had it never
# been tapped, she'd have been told about a move that never happened.
RSpec.describe "Buddy deferred actions" do
  let(:user)       { create(:user) }
  let(:partner)    { create(:user) }
  let(:her)        { partner.username } # first_name == username for factory users
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo)     {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }
  let(:at) { Time.current.tomorrow.change(hour: 13) }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(AgendaTravelChainSyncWorker).to receive(:perform_async)
    allow(Buddy::CompanionRelay).to receive(:deliver!)
    ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
    user.update!(chore_household_id: household.id)
    partner.update!(chore_household_id: household.id)
    convo.update_columns(buddy_theme: "byte")
  }

  def reply
    convo.byte_messages.where(direction: :inbound).order(:created_at).first
  end

  # The 1201 shape: a checkbox first, a partner message after it. The gate is a
  # chore rather than the agenda add of the original report, because agenda adds
  # have since moved to level 2 and run on arrival — any level-3 tool reproduces
  # the ordering this is about.
  def move_then_tell
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "add the costco run and let Chelsea know")
    client  = FakeBuddyClient.new([
      {
        tool_calls: [
          { name: :create_chore, call_id: "c1", arguments: { "name" => "Costco Run" } },
          { name: :message_partner, call_id: "c2", arguments: { "to" => her, "message" => "Costco Run's on the list." } },
        ],
      },
      { text: "Once you tap that, I'll let Chelsea know." },
    ])
    Buddy::GPT::Turn.run!(inbound, client: client)
    [reply, client]
  end

  def relays
    BuddyRelay.where(from_user_id: user.id)
  end

  def action_for(message)
    ByteAction.find_by(byte_message_id: message.id)
  end

  it "does not send the partner message while the checkbox is still waiting" do
    message, = move_then_tell

    expect(action_for(message).buttons.length).to eq(1)
    expect(relays).to be_empty
  end

  it "sends it once the checkbox is tapped" do
    message, = move_then_tell
    action   = action_for(message)

    Buddy::ProposalExecutor.perform(action.id, [1])

    expect(relays.count).to eq(1)
    expect(relays.first.body).to include("Costco Run")
  end

  it "runs it exactly once, even if the tap is replayed" do
    message, = move_then_tell
    action   = action_for(message)

    Buddy::ProposalExecutor.perform(action.id, [1])
    Buddy::ProposalExecutor.perform(action.id, [1])

    expect(relays.count).to eq(1)
  end

  it "never sends it when the thing it was announcing failed" do
    message, = move_then_tell
    action   = action_for(message)
    # The row resolves but blows up on execute — the move did not happen, so
    # neither should the announcement.
    allow(Buddy::Tools).to receive(:dispatch).and_return({ ok: false, error: "nope" })

    Buddy::ProposalExecutor.perform(action.id, [1])

    expect(relays).to be_empty
  end

  it "says what it held back, rather than going quiet about it" do
    message, = move_then_tell
    action   = action_for(message)
    allow(Buddy::Tools).to receive(:dispatch).and_return({ ok: false, error: "nope" })

    Buddy::ProposalExecutor.perform(action.id, [1])

    held = convo.byte_messages.where(direction: :inbound).order(:created_at).last
    expect(held.body).to include("Held off on")
    expect(held.body).to include("Message #{her}")
  end

  it "tells the model the follow-up is queued, not done" do
    _message, client = move_then_tell

    outputs = client.calls.last.input.select { |i| i[:type] == :function_call_output }
    queued  = JSON.parse(outputs.find { |o| o[:call_id] == "c2" }[:output])

    expect(queued["status"]).to eq("queued")
    expect(queued["note"]).to include("has NOT run")
  end

  it "leaves a level-1 call made BEFORE the checkbox firing immediately" do
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "tell Chelsea, and put Costco on the calendar")
    client  = FakeBuddyClient.new([
      {
        tool_calls: [
          { name: :message_partner, call_id: "c1", arguments: { "to" => her, "message" => "Heads up." } },
          { name: :add_agenda_item, call_id: "c2", arguments: { "title" => "Costco Run", "at" => at.iso8601 } },
        ],
      },
      { text: "Told her, and that one's ready to tap." },
    ])
    Buddy::GPT::Turn.run!(inbound, client: client)

    expect(relays.count).to eq(1)
  end

  it "leaves a turn with no checkbox at all completely alone" do
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "let Chelsea know I'm heading out")
    client  = FakeBuddyClient.new([
      { tool_calls: [{ name: :message_partner, call_id: "c1", arguments: { "to" => her, "message" => "Heading out." } }] },
      { text: "Told her." },
    ])
    Buddy::GPT::Turn.run!(inbound, client: client)

    expect(relays.count).to eq(1)
  end
end
