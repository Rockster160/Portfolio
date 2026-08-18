require "rails_helper"

# "Do X in two minutes" must not do X now.
#
# Prod 3897: "Add "something" to my todo list in 2 minutes" came back as
# add_list_item followed by set_timer(then_continue: true). ListItem 6397 was
# created on the spot at 18:15:16, byte_action 561 stored an EMPTY deferred
# queue, and timer 69 rang at 18:17 over a job already done. Reported as a very
# common shape: the trailing time phrase reads to the model as a second thing to
# do rather than as when to do the first, so it gets appended in the order it
# was spoken.
#
# `then_continue` is the model's own claim that the rest rides on the wait, so a
# wait with nothing behind it is a contradiction, and what it meant to hold is
# whatever it emitted just before.
RSpec.describe "Buddy dangling wait" do
  let(:user)   { create(:user) }
  let!(:todo)  { create(:list, user: user, name: "Todo") }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  # The suite runs Sidekiq inline, so a countdown started here would fire during
  # the example — and every assertion about what's still WAITING would really be
  # an assertion about how fast the spec ran.
  around { |ex| Sidekiq::Testing.fake! { ex.run } }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    TimerFireWorker.clear
    convo.update_columns(buddy_theme: "byte")
  }

  def ask(body, calls, reply: "Will do.")
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
    client  = FakeBuddyClient.new([{ tool_calls: calls }, { text: reply }])
    Buddy::GPT::Turn.run!(inbound, client: client)
    client
  end

  def add_item(call_id: "c1", item: "something")
    { name: :add_list_item, call_id: call_id, arguments: { "list" => "Todo", "item" => item } }
  end

  def wait_for(seconds, call_id: "c2", then_continue: true)
    args = { "seconds" => seconds }
    args["then_continue"] = true if then_continue
    { name: :set_timer, call_id: call_id, arguments: args }
  end

  def gate
    ByteAction.find_by(user_id: user.id, tool_name: Buddy::ProposalBuilder::TIMER_GATE)
  end

  def items
    ListItem.joins(:list).where(lists: { id: todo.id })
  end

  # The 3897 shape, exactly.
  describe "an action emitted BEFORE the wait it belongs behind" do
    before { ask("Add \"something\" to my todo list in 2 minutes", [add_item, wait_for(120)]) }

    it "does not add the item yet" do
      expect(items).to be_empty
    end

    it "parks the item on the countdown instead of leaving the queue empty" do
      expect(gate).to be_present
      expect(gate.tool_input["deferred"]).to be_present
    end

    it "adds it when the timer is up" do
      timer = Timer.find(gate.tool_input["timer_id"])

      Buddy::ProposalBuilder.resume_after!(timer)

      expect(items.pluck(:name)).to eq(["something"])
    end
  end

  # The flag is what makes the wait a wait. Without it there is nothing to
  # contradict, and "add milk and set a ten minute timer" is two ordinary
  # requests that both happen now.
  it "leaves a bare countdown alone" do
    ask(
      "Add milk to my todo list and set a 10 minute timer",
      [add_item(item: "milk"), wait_for(600, then_continue: false)],
    )

    expect(items.pluck(:name)).to eq(["milk"])
    expect(gate).to be_nil
  end

  # A real chain already puts its steps on the right side of the wait, and
  # rotating one would run it backwards. Each half stays where the model put it.
  it "leaves a wait that has a step after it alone" do
    ask(
      "Add milk now, then in a minute add eggs",
      [add_item(item: "milk"), wait_for(60), add_item(call_id: "c3", item: "eggs")],
    )

    expect(items.pluck(:name)).to eq(["milk"])

    Buddy::ProposalBuilder.resume_after!(Timer.find(gate.tool_input["timer_id"]))

    expect(items.pluck(:name)).to contain_exactly("milk", "eggs")
  end

  # Nothing came before it, so there is nothing it could have meant to hold —
  # and a lone wait is still an honest countdown.
  it "leaves a wait that is the only step alone" do
    ask("Give me two minutes", [wait_for(120, call_id: "c1")])

    expect(gate).to be_nil
  end
end
