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

  def add_call(id, title)
    { name: :add_agenda_item, call_id: id, arguments: { "title" => title, "at" => at.iso8601, "kind" => "task" } }
  end

  def tell_call(id, message)
    { name: :message_partner, call_id: id, arguments: { "to" => her, "message" => message } }
  end

  def answer_call(id, prompt)
    { name: :answer_prompt, call_id: id, arguments: { "id" => prompt.id, "answers" => { "Who did it?" => user.username } } }
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

  it "keeps two agenda items on one checklist rather than making them a chain" do
    turn!("add shower and laundry", [add_call("c1", "Shower"), add_call("c2", "Laundry")])

    expect(checklists.count).to eq(1)
    expect(checklists.first.buttons.pluck("label")).to eq(["Shower", "Laundry"])
  end

  # ---- chaining: one thing at a time, in the order it was asked for --------

  it "holds a checklist behind a form until the form is sent" do
    prompt = prompt_for("Puppy Down")

    turn!(
      "answer the puppy prompt then put laundry on my agenda",
      [answer_call("c1", prompt), add_call("c2", "Laundry")],
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
      [add_call("c1", "Laundry"), answer_call("c2", prompt)],
    )

    expect(forms).to be_empty
    expect(checklists.count).to eq(1)

    Buddy::ProposalExecutor.perform(checklists.first.id, [1])

    expect(forms.count).to eq(1)
    expect(forms.first.byte_message.body).to eq(prompt.question)
  end

  it "walks a three-step chain one gate at a time" do
    turn!("add shower, tell Chelsea, then add laundry", [
      add_call("c1", "Shower"),
      tell_call("c2", "Shower's on the agenda."),
      add_call("c3", "Laundry"),
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
      add_call("c1", "Shower"),
      answer_call("c2", prompt),
      add_call("c3", "Laundry"),
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

  # ---- the escape hatch ---------------------------------------------------

  it "never advances on its own — an untouched gate leaves the rest unposted" do
    prompt = prompt_for("Puppy Down")
    turn!("laundry then the prompt", [add_call("c1", "Laundry"), answer_call("c2", prompt)])

    expect(forms).to be_empty
    expect(checklists.first).to be_pending
  end

  it "says what it held back when the gate is declined outright" do
    prompt = prompt_for("Puppy Down")
    turn!("laundry then the prompt", [add_call("c1", "Laundry"), answer_call("c2", prompt)])
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
    client = turn!("the prompt, then laundry", [answer_call("c1", prompt), add_call("c2", "Laundry")])

    outputs = client.calls.last.input.select { |i| i[:type] == :function_call_output }
    chained = JSON.parse(outputs.find { |o| o[:call_id] == "c2" }[:output])

    expect(chained["status"]).to eq("queued")
    expect(chained["note"]).to include("next in line")
  end

  # ---- rows written before the queue understood steps ---------------------

  it "still fires a queue stored in the old flat shape" do
    turn!("move it and tell her", [add_call("c1", "Costco Run"), tell_call("c2", "Moved it.")])
    action = checklists.first
    flat   = action.tool_input["deferred"].flat_map { |step| step["calls"] }
    action.update!(tool_input: { "deferred" => flat })

    Buddy::ProposalExecutor.perform(action.id, [1])

    expect(relays.count).to eq(1)
  end
end
