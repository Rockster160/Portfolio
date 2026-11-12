require "rails_helper"

# Steps chained onto a countdown that was already running: no second timer, the
# original still rings, and the steps run when it does.
RSpec.describe "Buddy follow-ups on a running timer" do
  let(:user)       { create(:user) }
  let!(:groceries) { create(:list, user: user, name: "Groceries") }
  let!(:convo)     {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }
  let!(:pasta) { Buddy::Timers.create!(user: user, seconds: 600, label: "pasta", conversation: convo) }

  # The suite runs Sidekiq inline, so a countdown started here would fire during
  # the example.
  around { |ex| Sidekiq::Testing.fake! { ex.run } }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    TimerFireWorker.clear
    convo.update_columns(buddy_theme: "byte")
  }

  def ask(body, calls)
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
    client  = FakeBuddyClient.new([{ tool_calls: calls }, { text: "Will do." }])
    Buddy::GPT::Turn.run!(inbound, client: client)
    client
  end

  def after_timer(match, call_id: "c1")
    { name: :set_timer, call_id: call_id, arguments: { "after_timer" => match, "then_continue" => true } }
  end

  def add_item(item, call_id: "c2")
    { name: :add_list_item, call_id: call_id, arguments: { "list" => "Groceries", "item" => item } }
  end

  def items
    ListItem.joins(:list).where(lists: { id: groceries.id }).pluck(:name)
  end

  def gates
    ByteAction.where(user_id: user.id, tool_name: Buddy::ProposalBuilder::TIMER_GATE)
  end

  def fire!(timer)
    timer.update!(fired_at: Time.current)
    Buddy::Timers.on_fired(timer.reload)
  end

  def bodies
    convo.byte_messages.order(:id).pluck(:body)
  end

  def output_for(client, call_id)
    outputs = client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }
    JSON.parse(outputs.find { |o| o[:call_id] == call_id }[:output])
  end

  it "holds the step on the running timer without starting another", :aggregate_failures do
    ask("When the pasta timer's done, add parmesan to groceries", [after_timer("pasta"), add_item("parmesan")])

    expect(items).to be_empty
    expect(user.timers.count).to eq(1)
    expect(gates.pending.sole.tool_input["timer_id"]).to eq(pasta.id)
    expect(Buddy::Timers.wait?(pasta.reload)).to be(false)
    expect(bodies).to include("Byte will do the next step when the pasta timer is up ⏲")
  end

  it "rings the timer as usual and then runs the step", :aggregate_failures do
    ask("When the pasta timer's done, add parmesan to groceries", [after_timer("pasta"), add_item("parmesan")])

    fire!(pasta)

    expect(items).to eq(["parmesan"])
    expect(bodies).to include("⏲ Time's up - your pasta timer's done!")
    expect(pasta.reload.archived_at).to be_nil
  end

  it "runs everything chained on at different times, each once", :aggregate_failures do
    ask("When the pasta timer's done, add parmesan to groceries", [after_timer("pasta"), add_item("parmesan")])
    ask("After my timer, add basil to groceries too", [after_timer("mine"), add_item("basil")])

    fire!(pasta)
    Buddy::ProposalBuilder.resume_after!(pasta)

    expect(items).to contain_exactly("parmesan", "basil")
  end

  it "says what it won't do when the timer is cancelled first", :aggregate_failures do
    ask("When the pasta timer's done, add parmesan to groceries", [after_timer("pasta"), add_item("parmesan")])

    Buddy::Timers.stop!(pasta)

    expect(items).to be_empty
    expect(bodies.last).to match(/\AThe pasta timer was stopped, so I didn't go on to .*parmesan/i)
    expect(gates.pending).to be_empty
  end

  it "says the same for a wait Buddy started" do
    ask("Add milk to groceries in 5 minutes", [
      { name: :set_timer, call_id: "c1", arguments: { "seconds" => 300, "then_continue" => true } },
      add_item("milk"),
    ])
    wait = Timer.find(gates.pending.sole.tool_input["timer_id"])

    Buddy::Timers.stop!(wait)

    expect(bodies.last).to match(/\AThe timer was stopped, so I didn't go on to .*milk/i)
  end

  it "shows what's riding the timer to Buddy" do
    ask("When the pasta timer's done, add parmesan to groceries", [after_timer("pasta"), add_item("parmesan")])

    seen = Buddy::Context.send(:running_timers, user).sole
    expect(seen[:then]).to match(/parmesan/i)
  end

  it "refuses when nothing matches, and does the step nowhere", :aggregate_failures do
    Buddy::Timers.create!(user: user, seconds: 300, label: "tea", conversation: convo)
    client = ask("When the rice timer's done, add parmesan", [after_timer("rice"), add_item("parmesan")])

    expect(output_for(client, "c1")["error"]).to eq("no running timer matching \"rice\"")
    expect(gates).to be_empty
    expect(items).to be_empty
  end

  it "carries a step on a timer that starts later over to the real one, and runs it when that ends", :aggregate_failures do
    pasta.update!(archived_at: Time.current)
    later = Buddy::Timers.schedule!(user: user, starts_at: 10.minutes.from_now, seconds: 600, label: "bread", conversation: convo)
    ask("When the bread timer's done, add butter to groceries", [after_timer("bread"), add_item("butter")])

    real = Buddy::Timers.start_scheduled!(later)

    expect(gates.pending.sole.tool_input["timer_id"]).to eq(real.id)
    expect(bodies.last).not_to match(/was stopped/)
    expect(items).to be_empty

    fire!(real)

    expect(items).to eq(["butter"])
  end

  it "refuses a cycle, which has no end to wait for" do
    cycle = Buddy::TimerCycle.start!(user: user, conversation: convo, seconds: 1800, label: "focus")
    expect {
      Buddy::Tools::SetTimer.running_timer!(user, cycle.id.to_s)
    }.to raise_error(/goes round until it's tapped/)
  end
end
