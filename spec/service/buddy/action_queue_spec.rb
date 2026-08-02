require "rails_helper"

# What Buddy asks for in one turn becomes ordered STEPS, and only the first thing
# that needs the person goes out with the reply. The rest rides on it and lands
# when they resolve it.
#
# Two failures drove this. Prod 1201: a partner message fired 22 seconds before
# the checkbox that would have made it true. Prod 1266-1270: three pending
# prompts, answered in one sentence, and Buddy opened exactly one of them.
RSpec.describe "Buddy action queue" do
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
    allow(::WebPushNotifications).to receive(:update_count)
    allow(AgendaTravelChainSyncWorker).to receive(:perform_async)
    allow(Buddy::CompanionRelay).to receive(:deliver!)
    allow(::Jil).to receive(:trigger).and_return(true)
    ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
    user.update!(chore_household_id: household.id)
    partner.update!(chore_household_id: household.id)
    convo.update_columns(buddy_theme: "byte")
  }

  def prompt_for(name)
    Prompt.create!(user: user, answer_type: :single, question: "Who did: #{name}?", options: [
      { "type" => "text", "default" => "", "question" => "Who did it?" },
    ])
  end

  def turn!(body, tool_calls, text: "Here you go.")
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
    client  = FakeBuddyClient.new([{ tool_calls: tool_calls }, { text: text }])
    Buddy::GPT::Turn.run!(inbound, client: client)
    client
  end

  # A gate: something that waits for a tap. Any level-3 tool does — what's being
  # tested is the queue, not the event. Agenda and chore writes have both since
  # moved to level 2 and run on arrival, so an edit to a logged event is the
  # cheapest thing left that still waits on the person.
  def gate_call(id, title)
    ActionEvent.find_or_create_by!(user: user, name: title) { |e| e.timestamp = Time.current }
    { name: :edit_event, call_id: id, arguments: { "event" => title, "notes" => "from #{id}" } }
  end

  def tell_call(id, message)
    { name: :message_partner, call_id: id, arguments: { "to" => her, "message" => message } }
  end

  def answer_call(id, prompt)
    { name: :answer_prompt, call_id: id, arguments: { "id" => prompt.id, "answers" => { "Who did it?" => user.username } } }
  end

  def wait_call(id, seconds)
    { name: :set_timer, call_id: id, arguments: { "seconds" => seconds, "then_continue" => true } }
  end

  def timer_call(id, seconds)
    { name: :set_timer, call_id: id, arguments: { "seconds" => seconds } }
  end

  def timer_gates
    ByteAction.where(byte_conversation: convo, tool_name: Buddy::ProposalBuilder::TIMER_GATE).order(:id)
  end

  # Oldest first. Timer.ordered sorts by board position and then id DESCENDING,
  # which is the wrong end when a spec wants "the wait that was set first".
  def timers
    Timer.where(user_id: user.id, kind: :countdown).order(:id)
  end

  def forms
    ByteAction.where(byte_conversation: convo, tool_name: Buddy::FormAction::TOOL_NAME).order(:id)
  end

  def checklists
    ByteAction.where(byte_conversation: convo, tool_name: "buddy_proposals").order(:id)
  end

  def relays
    BuddyRelay.where(from_user_id: user.id)
  end

  # ---- batching: things asked for together still arrive together -----------

  it "posts every prompt at once when one message answers all of them" do
    prompts = ["Puppy Down", "Puppy Fed", "Puppy Up"].map { |n| prompt_for(n) }

    turn!(
      "I did the down, Chelsea did the others",
      prompts.each_with_index.map { |p, i| answer_call("c#{i}", p) },
    )

    expect(forms.count).to eq(3)
    expect(forms.map { |a| a.byte_message.body }).to eq(prompts.map(&:question))
    # All three are live right now — none is waiting on another.
    expect(forms.map(&:state).uniq).to eq(["pending"])
  end

  it "keeps two of them on one checklist rather than making them a chain" do
    turn!("add shower and laundry", [gate_call("c1", "Shower"), gate_call("c2", "Laundry")])

    expect(checklists.count).to eq(1)
    expect(checklists.first.buttons.pluck("label")).to eq(["Shower", "Laundry"])
  end

  # ---- chaining: one thing at a time, in the order it was asked for --------

  it "holds a checklist behind a form until the form is sent" do
    prompt = prompt_for("Puppy Down")

    turn!(
      "answer the puppy prompt then put laundry on my agenda",
      [answer_call("c1", prompt), gate_call("c2", "Laundry")],
    )

    expect(forms.count).to eq(1)
    expect(checklists).to be_empty

    Buddy::FormAction.submit!(forms.first, values: { "Who did it?" => user.username })

    expect(checklists.count).to eq(1)
    expect(checklists.first.buttons.pluck("label")).to eq(["Laundry"])
    expect(checklists.first.byte_message.body).to eq("Next up:")
  end

  it "holds a form behind a checklist until the checkbox is tapped" do
    prompt = prompt_for("Puppy Down")

    turn!(
      "add laundry, then let's do that prompt",
      [gate_call("c1", "Laundry"), answer_call("c2", prompt)],
    )

    expect(forms).to be_empty
    expect(checklists.count).to eq(1)

    Buddy::ProposalExecutor.perform(checklists.first.id, [1])

    expect(forms.count).to eq(1)
    expect(forms.first.byte_message.body).to eq(prompt.question)
  end

  it "walks a three-step chain one gate at a time" do
    turn!("add shower, tell Chelsea, then add laundry", [
      gate_call("c1", "Shower"),
      tell_call("c2", "Shower's on the agenda."),
      gate_call("c3", "Laundry"),
    ])

    expect(checklists.count).to eq(1)
    expect(relays).to be_empty

    Buddy::ProposalExecutor.perform(checklists.first.id, [1])

    # The message goes out AND the next checklist appears, in that order.
    expect(relays.count).to eq(1)
    expect(checklists.count).to eq(2)
    expect(checklists.last.buttons.pluck("label")).to eq(["Laundry"])
  end

  it "carries the rest of the chain onto whatever it just posted" do
    prompt = prompt_for("Puppy Down")
    turn!("add shower, do the prompt, then add laundry", [
      gate_call("c1", "Shower"),
      answer_call("c2", prompt),
      gate_call("c3", "Laundry"),
    ])

    # Gate 1 is the Shower checklist; the form and the second checklist wait.
    expect(checklists.count).to eq(1)
    expect(forms).to be_empty

    Buddy::ProposalExecutor.perform(checklists.first.id, [1])

    # Gate 2 is the form, and it took the last step along with it.
    expect(forms.count).to eq(1)
    expect(checklists.count).to eq(1)
    expect(forms.first.tool_input["deferred"].pluck("kind")).to eq(["rows"])

    Buddy::FormAction.submit!(forms.first, values: { "Who did it?" => user.username })

    expect(checklists.count).to eq(2)
    expect(checklists.last.buttons.pluck("label")).to eq(["Laundry"])
    expect(checklists.last.tool_input["deferred"]).to be_blank
  end

  # ---- waiting: the gate is the clock, not the person ----------------------
  #
  # Prod 1307: "Start my printer, wait 1m, then preheat it for PLA." started the
  # printer and the timer, then offered to maybe do the preheat - which was the
  # part they'd actually asked for.
  describe "a wait in the middle of a sequence" do
    # Timers schedule their own fire job, and the suite runs Sidekiq inline, so
    # without this a one-minute wait would fire during the example.
    around { |ex| Sidekiq::Testing.fake! { ex.run } }

    it "holds everything after the wait until the countdown fires" do
      turn!("start the printer, wait a minute, then tell Chelsea", [
        tell_call("c1", "Printer's on."),
        wait_call("c2", 60),
        tell_call("c3", "Preheating now."),
      ])

      # The first message went out, the timer is running, and the second message
      # is parked on it rather than sent alongside the first.
      expect(relays.pluck(:body)).to eq(["Printer's on."])
      expect(timers.count).to eq(1)
      expect(timer_gates.count).to eq(1)

      Buddy::Timers.on_fired(timers.first)

      expect(relays.pluck(:body)).to eq(["Printer's on.", "Preheating now."])
      expect(timer_gates.first.reload).to be_decided
    end

    it "posts a checklist held behind a wait only once the wait is over" do
      turn!("wait a minute then add laundry", [wait_call("c1", 60), gate_call("c2", "Laundry")])

      expect(checklists).to be_empty

      Buddy::Timers.on_fired(timers.first)

      expect(checklists.count).to eq(1)
      expect(checklists.first.buttons.pluck("label")).to eq(["Laundry"])
    end

    it "runs the follow-up once even if the fire job is delivered twice" do
      turn!("wait a minute then tell Chelsea", [wait_call("c1", 60), tell_call("c2", "Done waiting.")])
      timer = timers.first

      2.times { Buddy::Timers.on_fired(timer) }

      expect(relays.count).to eq(1)
    end

    it "says it's picking the sequence back up rather than that time is up" do
      turn!("wait a minute then tell Chelsea", [wait_call("c1", 60), tell_call("c2", "Hi.")])
      Buddy::Timers.on_fired(timers.first)

      bodies = convo.byte_messages.where(direction: :inbound).pluck(:body)
      expect(bodies).to include(a_string_matching(/picking it back up/))
      expect(bodies).not_to include(a_string_matching(/Time's up/))
      expect(bodies).to include(a_string_matching(/waiting 1 min before the next step/))
    end

    # An ordinary countdown is not a sequence. "Set a 10 minute timer and tell
    # Chelsea" must not park the message behind the timer.
    it "leaves a plain countdown out of the way" do
      turn!("10 minute timer and tell Chelsea", [timer_call("c1", 600), tell_call("c2", "Timer's going.")])

      expect(relays.count).to eq(1)
      expect(timer_gates).to be_empty
    end

    it "nests a second wait instead of collapsing the two" do
      turn!("wait a minute, tell her, wait another, tell her again", [
        wait_call("c1", 60),
        tell_call("c2", "First."),
        wait_call("c3", 60),
        tell_call("c4", "Second."),
      ])

      expect(relays).to be_empty

      Buddy::Timers.on_fired(timers.first)

      expect(relays.pluck(:body)).to eq(["First."])
      expect(timers.count).to eq(2)

      Buddy::Timers.on_fired(timers.last)

      expect(relays.pluck(:body)).to eq(["First.", "Second."])
    end

    it "tells the model the held step happens on its own, not on a tap" do
      client = turn!("wait a minute then tell Chelsea", [wait_call("c1", 60), tell_call("c2", "Hi.")])

      outputs = client.calls.last.input.select { |i| i[:type] == :function_call_output }
      held    = JSON.parse(outputs.find { |o| o[:call_id] == "c2" }[:output])

      expect(held["status"]).to eq("queued")
      expect(held["note"]).to include("on its own")
      expect(held["note"]).not_to include("tap")
    end

    # A countdown that never starts can't hold anything, and silently swallowing
    # the rest of the sequence is worse than running it a minute early.
    it "runs the rest immediately when the wait itself fails to start" do
      allow(Buddy::Timers).to receive(:create!).and_raise(StandardError, "redis down")

      turn!("wait a minute then tell Chelsea", [wait_call("c1", 60), tell_call("c2", "Hi.")])

      expect(relays.count).to eq(1)
      expect(timer_gates).to be_empty
    end
  end

  # ---- the escape hatch ---------------------------------------------------

  it "never advances on its own — an untouched gate leaves the rest unposted" do
    prompt = prompt_for("Puppy Down")
    turn!("laundry then the prompt", [gate_call("c1", "Laundry"), answer_call("c2", prompt)])

    expect(forms).to be_empty
    expect(checklists.first).to be_pending
  end

  it "says what it held back when the gate is declined outright" do
    prompt = prompt_for("Puppy Down")
    turn!("laundry then the prompt", [gate_call("c1", "Laundry"), answer_call("c2", prompt)])
    allow(Buddy::Tools).to receive(:dispatch).and_return({ ok: false, error: "nope" })

    Buddy::ProposalExecutor.perform(checklists.first.id, [1])

    expect(forms).to be_empty
    expect(convo.byte_messages.where(direction: :inbound).last.body).to include("Held off on")
  end

  # ---- level 2 never waits ------------------------------------------------

  it "runs a level-2 row on arrival even when a form was asked for first" do
    prompt = prompt_for("Puppy Down")
    list   = create(:list, user: user, name: "Groceries")

    turn!("do the prompt and put milk on groceries", [
      answer_call("c1", prompt),
      { name: :add_list_item, call_id: "c2", arguments: { "list" => "Groceries", "item" => "Milk" } },
    ])

    expect(list.list_items.reload.pluck(:name)).to eq(["Milk"])
    expect(forms.count).to eq(1)
    expect(checklists.count).to eq(1)
  end

  # ---- what the model is told ---------------------------------------------

  it "tells the model a chained gate is next in line, not waiting on them" do
    prompt = prompt_for("Puppy Down")
    client = turn!("the prompt, then laundry", [answer_call("c1", prompt), gate_call("c2", "Laundry")])

    outputs = client.calls.last.input.select { |i| i[:type] == :function_call_output }
    chained = JSON.parse(outputs.find { |o| o[:call_id] == "c2" }[:output])

    expect(chained["status"]).to eq("queued")
    expect(chained["note"]).to include("next in line")
  end

  # ---- rows written before the queue understood steps ---------------------

  it "still fires a queue stored in the old flat shape" do
    turn!("move it and tell her", [gate_call("c1", "Costco Run"), tell_call("c2", "Moved it.")])
    action = checklists.first
    flat   = action.tool_input["deferred"].flat_map { |step| step["calls"] }
    action.update!(tool_input: { "deferred" => flat })

    Buddy::ProposalExecutor.perform(action.id, [1])

    expect(relays.count).to eq(1)
  end
end
