require "rails_helper"

# A routine is a name for a sequence: "prep my printer" is power the printer on,
# wait a minute, then preheat. It stores the same markers a live turn produces
# and replays them through ProposalBuilder, so ordering, gates and waits all
# come along for free.
RSpec.describe "Buddy routines" do
  let(:user)    { create(:user) }
  let(:partner) { create(:user) }
  let(:her)     { partner.username }
  let!(:household) { ChoreHousehold.create!(name: "Home", owner_user: user) }
  let!(:convo) {
    user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: Time.current)
  }

  before {
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    allow(::WebPushNotifications).to receive(:update_count)
    allow(Buddy::CompanionRelay).to receive(:deliver!)
    allow(::Jil).to receive(:trigger).and_return(true)
    ChoreHouseholdMembership.create!(chore_household: household, user: partner, role: :member)
    user.update!(chore_household_id: household.id)
    partner.update!(chore_household_id: household.id)
    convo.update_columns(buddy_theme: "byte")
  }

  def turn!(body, tool_calls, text: "Here you go.")
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
    client  = FakeBuddyClient.new([{ tool_calls: tool_calls }, { text: text }])
    Buddy::GPT::Turn.run!(inbound, client: client)
    client
  end

  def run_call(name)
    { name: :run_routine, call_id: "r1", arguments: { "name" => name } }
  end

  def chips
    convo.byte_messages.where(direction: :inbound).order(:id).select { |m|
      m.metadata.is_a?(Hash) && m.metadata["kind"] == "buddy_activity"
    }
  end

  # Two message_partner calls leave the same receipt text, so the chip BODY
  # can't tell them apart. The arguments it ran with can.
  def told
    chips.filter_map { |c| c.metadata.dig("args", "message") }
  end

  def timers
    Timer.where(user_id: user.id, kind: :countdown).order(:id)
  end

  def timer_gates
    ByteAction.where(byte_conversation: convo, tool_name: Buddy::ProposalBuilder::TIMER_GATE).order(:id)
  end

  def checklists
    ByteAction.where(byte_conversation: convo, tool_name: "buddy_proposals").order(:id)
  end

  def routine!(name, steps, **attrs)
    BuddyRoutine.create!(user: user, name: name, steps: steps, **attrs)
  end

  def tell_step(message)
    BuddyRoutine.step(:message_partner, { to: her, message: message })
  end

  # ---- running one ---------------------------------------------------------

  describe "running a routine" do
    it "runs every step, in the order it was saved" do
      routine!("Nightly", [tell_step("locking up"), tell_step("night")])

      turn!("do the nightly thing", [run_call("Nightly")])

      expect(told).to eq(["locking up", "night"])
    end

    it "matches the name loosely, the way they'd actually say it" do
      routine!("Prep Printer", [tell_step("printer's on")])

      turn!("prep the printer please", [run_call("prep printer")])

      expect(chips.length).to eq(1)
    end

    it "says so rather than running something else when nothing matches" do
      routine!("Nightly", [tell_step("night")])

      client = turn!("do the morning thing", [run_call("Morning Sweep")])

      expect(chips).to be_empty
      output = JSON.parse(client.calls.last.input.select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["status"]).to eq("failed")
      expect(output["error"]).to match(/no routine called/i)
    end

    it "leaves a disabled routine alone" do
      routine!("Nightly", [tell_step("night")], enabled: false)

      turn!("nightly", [run_call("Nightly")])

      expect(chips).to be_empty
    end

    it "counts the runs, so a routine nobody uses is visible as one" do
      routine = routine!("Nightly", [tell_step("night")])

      turn!("nightly", [run_call("Nightly")])

      expect(routine.reload.run_count).to eq(1)
      expect(routine.last_run_at).to be_present
    end
  end

  # ---- the whole point: a wait inside a saved sequence ----------------------

  describe "a routine with a wait in it" do
    around { |ex| Sidekiq::Testing.fake! { ex.run } }

    let!(:routine) {
      routine!("Prep Printer", [
        tell_step("printer's on"),
        BuddyRoutine.step(:set_timer, { seconds: 60, then_continue: true }),
        tell_step("preheating now"),
      ])
    }

    it "holds the steps after the wait until the timer fires" do
      turn!("prep my printer", [run_call("Prep Printer")])

      expect(told).to eq(["printer's on"])
      expect(timer_gates.count).to eq(1)
    end

    it "picks the rest back up on its own when the wait is over" do
      turn!("prep my printer", [run_call("Prep Printer")])
      Buddy::Timers.on_fired(timers.last)

      expect(told).to eq(["printer's on", "preheating now"])
      expect(timer_gates.first.reload.state).to eq("decided")
    end

    it "tells the model the held step happens on its own, so it won't offer it" do
      client = turn!("prep my printer", [run_call("Prep Printer")])

      output = JSON.parse(client.calls.last.input.select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["status"]).to eq("waiting")
    end
  end

  # ---- saving ---------------------------------------------------------------

  describe "saving one they described" do
    def save_call(name, steps)
      {
        name:      :save_routine,
        call_id:   "s1",
        arguments: { "name" => name, "steps" => JSON.generate(steps) },
      }
    end

    it "stores the steps as given, ready to replay" do
      turn!("when I say nightly, tell her goodnight", [
        save_call("Nightly", [{ tool_name: "message_partner", payload: { to: her, message: "goodnight" } }]),
      ])

      routine = user.buddy_routines.find_by(name: "Nightly")
      expect(routine.steps.length).to eq(1)
      expect(routine.steps.first["tool_name"]).to eq("message_partner")
      expect(routine.steps.first["payload"]).to include("message" => "goodnight")
    end

    it "replaces the steps when they save over a name, rather than making a second one" do
      routine!("Nightly", [tell_step("old")])

      turn!("change nightly", [
        save_call("Nightly", [{ tool_name: "message_partner", payload: { to: her, message: "new" } }]),
      ])

      expect(user.buddy_routines.count).to eq(1)
      expect(user.buddy_routines.first.steps.first["payload"]["message"]).to eq("new")
    end

    it "refuses a step whose tool doesn't exist instead of saving something broken" do
      client = turn!("save this", [
        save_call("Nope", [{ tool_name: "launch_rocket", payload: {} }]),
      ])

      expect(user.buddy_routines.count).to eq(0)
      output = JSON.parse(client.calls.last.input.select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["error"]).to match(/no tool called/i)
    end

    it "refuses a step that's missing a required argument" do
      client = turn!("save this", [
        save_call("Nope", [{ tool_name: "message_partner", payload: { to: her } }]),
      ])

      expect(user.buddy_routines.count).to eq(0)
      output = JSON.parse(client.calls.last.input.select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["error"]).to match(/missing required arg/i)
    end

    it "keeps a call that only means something once out of a routine" do
      client = turn!("save this", [
        save_call("Nope", [{ tool_name: "undo", payload: {} }]),
      ])

      expect(user.buddy_routines.count).to eq(0)
      output = JSON.parse(client.calls.last.input.select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["error"]).to match(/can't be saved in a routine/i)
    end
  end

  # ---- saving what just happened -------------------------------------------

  describe "saving what it just did" do
    def capture_call(name, count)
      { name: :save_routine, call_id: "s1", arguments: { "name" => name, "capture_last" => count } }
    end

    it "reads the steps back off the calls that actually ran" do
      turn!("tell her twice", [
        { name: :message_partner, call_id: "a", arguments: { "to" => her, "message" => "one" } },
        { name: :message_partner, call_id: "b", arguments: { "to" => her, "message" => "two" } },
      ])

      turn!("save that as nightly", [capture_call("Nightly", 2)])

      routine = user.buddy_routines.find_by(name: "Nightly")
      expect(routine.steps.map { |s| s["payload"]["message"] }).to eq(%w[one two])
    end

    it "saves only the last N, so an unrelated earlier call doesn't ride along" do
      turn!("tell her", [{ name: :message_partner, call_id: "a", arguments: { "to" => her, "message" => "old" } }])
      turn!("tell her again", [{ name: :message_partner, call_id: "b", arguments: { "to" => her, "message" => "new" } }])

      turn!("save that", [capture_call("Nightly", 1)])

      expect(user.buddy_routines.first.steps.map { |s| s["payload"]["message"] }).to eq(["new"])
    end

    it "says it has nothing to save rather than inventing steps" do
      client = turn!("save that", [capture_call("Nightly", 2)])

      expect(user.buddy_routines.count).to eq(0)
      output = JSON.parse(client.calls.last.input.select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["error"]).to match(/can't find anything/i)
    end

    # The model cannot see its own activity chips (History keeps them out), so a
    # capture is the only honest way to save what just ran.
    it "captures a wait with its then_continue intact, so the saved copy still pauses" do
      Sidekiq::Testing.fake! {
        turn!("tell her, wait a minute, tell her again", [
          { name: :message_partner, call_id: "a", arguments: { "to" => her, "message" => "one" } },
          { name: :set_timer, call_id: "b", arguments: { "seconds" => 60, "then_continue" => true } },
          { name: :message_partner, call_id: "c", arguments: { "to" => her, "message" => "two" } },
        ])
        Buddy::Timers.on_fired(Timer.where(user_id: user.id, kind: :countdown).order(:id).last)

        turn!("save that as prep", [capture_call("Prep", 3)])
      }

      steps = user.buddy_routines.find_by(name: "Prep").steps
      expect(steps.pluck("tool_name")).to eq(%w[message_partner set_timer message_partner])
      expect(steps[1]["payload"]).to include("then_continue" => true)
    end
  end

  # ---- storing arguments rather than resolved ids ---------------------------

  describe "what a step stores" do
    it "keeps the name that was asked for, not the id it resolved to" do
      create(:chore, created_by_user: user, chore_household: household, name: "Feed Byte")

      turn!("fed byte", [
        { name: :complete_chore, call_id: "a", arguments: { "chore" => "feed byte" } },
      ])
      turn!("save that", [
        { name: :save_routine, call_id: "s1", arguments: { "name" => "Feed", "capture_last" => 1 } },
      ])

      payload = user.buddy_routines.find_by(name: "Feed").steps.first["payload"]
      expect(payload).to include("chore" => "feed byte")
      expect(payload.keys).not_to include("chore_id", "chore_name")
    end

    it "resolves the name fresh at run time rather than trusting a saved id" do
      create(:chore, created_by_user: user, chore_household: household, name: "Feed Byte")
      routine!("Feed", [BuddyRoutine.step(:complete_chore, { chore: "feed byte" })])

      turn!("feed routine", [run_call("Feed")])

      expect(ChoreCompletion.where(user_id: user.id).count).to eq(1)
    end
  end

  # ---- forgetting -----------------------------------------------------------

  describe "deleting one" do
    it "removes it once the row is tapped" do
      routine!("Nightly", [tell_step("night")])

      turn!("drop the nightly routine", [
        { name: :forget_routine, call_id: "f1", arguments: { "name" => "Nightly" } },
      ])
      action = checklists.last
      Buddy::ProposalExecutor.perform(action.id, action.buttons.pluck("id"))

      expect(user.buddy_routines.count).to eq(0)
    end
  end

  # ---- what Buddy sees ------------------------------------------------------

  describe "the routines index" do
    it "lists them with a readable summary of what each one does" do
      steps = [
        BuddyRoutine.step(:set_timer, { seconds: 60, then_continue: true }),
        tell_step("preheating"),
      ]
      routine!("Prep Printer", steps, description: "Gets the printer going")

      row = Buddy::Context.build(user, convo)[:routines].first

      expect(row[:name]).to eq("Prep Printer")
      expect(row[:description]).to eq("Gets the printer going")
      expect(row[:steps].length).to eq(2)
    end

    it "leaves a disabled routine out, so Buddy can't offer one that won't run" do
      routine!("Off", [tell_step("night")], enabled: false)

      expect(Buddy::Context.build(user, convo)[:routines]).to be_empty
    end
  end
end
