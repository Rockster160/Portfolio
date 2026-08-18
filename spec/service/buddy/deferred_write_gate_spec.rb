require "rails_helper"

# The gate that holds an immediate tool back when the request said WHEN.
#
# It has always existed for the device verbs (prod 3562, "Play Whisper Nap sound
# at 11", which played it 16 minutes early next to a sleeping dog). Prod 3897
# walked straight past it twice over: "Add "something" to my todo list in 2
# minutes" opens with a verb the command regex doesn't know, and `add_list_item`
# was not on the list of tools it guards.
RSpec.describe "Buddy deferred write gate" do
  let(:user)   { create(:user) }
  let!(:todo)  { create(:list, user: user, name: "Todo") }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  around { |ex| Sidekiq::Testing.fake! { ex.run } }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    TimerFireWorker.clear
    convo.update_columns(buddy_theme: "byte")
  }

  def ask(body, calls)
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
    client  = FakeBuddyClient.new([{ tool_calls: calls }, { text: "Sorted." }])
    Buddy::GPT::Turn.run!(inbound, client: client)
    client
  end

  def add_item(item: "something", call_id: "c1")
    { name: :add_list_item, call_id: call_id, arguments: { "list" => "Todo", "item" => item } }
  end

  def timer(seconds, then_continue: false, call_id: "c2")
    args = { "seconds" => seconds }
    args["then_continue"] = true if then_continue
    { name: :set_timer, call_id: call_id, arguments: args }
  end

  def items
    ListItem.joins(:list).where(lists: { id: todo.id })
  end

  # What the model was told about the call it made.
  def output_for(client, call_id)
    outputs = client.calls.last.input.select { |i| i[:type] == :function_call_output }
    JSON.parse(outputs.find { |o| o[:call_id] == call_id }[:output])
  end

  # The 3897 shape with the flag left off: the write plus a plain countdown.
  # ProposalBuilder can't see this one — a bare timer defers nothing and looks
  # exactly like an ordinary countdown — so the gate is the only thing between
  # the item and the list.
  describe "a write with a time on it, answered with a bare countdown" do
    let!(:client) { ask("Add \"something\" to my todo list in 2 minutes", [add_item, timer(120)]) }

    it "does not add it" do
      expect(items).to be_empty
    end

    it "tells the model it did not run, and why" do
      held = output_for(client, "c1")

      expect(held["status"]).to eq("failed")
      expect(held["note"]).to include("says when to act")
    end
  end

  # The other half of the same sentence, and it must still work: no time named
  # means nothing to defer.
  it "adds it when no time was named" do
    ask("Add milk to my todo list", [add_item(item: "milk")])

    expect(items.pluck(:name)).to eq(["milk"])
  end

  # A WAIT is the model getting it right — it says the rest of the sequence
  # rides on the countdown — so the gate steps aside and ProposalBuilder takes
  # over. Without this the two fixes would fight, and the gate would refuse the
  # very shape it's trying to teach.
  it "stands aside for a wait that carries the rest of the sequence" do
    ask(
      "Add milk to my todo list in 2 minutes",
      [timer(120, then_continue: true, call_id: "c1"), add_item(item: "milk", call_id: "c2")],
    )

    expect(items).to be_empty
    expect(ByteAction.where(tool_name: Buddy::ProposalBuilder::TIMER_GATE)).to be_present
  end

  # "Remind me at 5 to call mom, and add milk to the list" names a time and then
  # asks for something NOW. Which call the model emits first is arbitrary, and
  # reading them one at a time meant the reminder only covered the milk when it
  # happened to come first.
  it "lets a write through when the round also scheduled something, whichever order" do
    ask("Add milk to my list, and remind me at 5 to call mom", [
      add_item(item: "milk", call_id: "c1"),
      {
        name:      :schedule_reminder,
        call_id:   "c2",
        arguments: { "text" => "Call mom", "at" => Time.current.change(hour: 17).iso8601 },
      },
    ])

    expect(items.pluck(:name)).to eq(["milk"])
  end

  # The device half of the gate is untouched by any of this — prod 3562 stays
  # caught.
  it "still holds back a device command that named a time" do
    task = Task.create!(
      user: user, name: "Nap Sound", listener: "function(\"Nap\")",
      code: "", enabled: true, buddy_enabled: true
    )
    allow(Jil::Executor).to receive(:call)

    client = ask("Play the nap sound at 11", [
      { name: :call_jil_function, call_id: "c1", arguments: { "name" => task.name, "args" => {} } },
    ])

    expect(Jil::Executor).not_to have_received(:call)
    expect(output_for(client, "c1")["status"]).to eq("failed")
  end
end
