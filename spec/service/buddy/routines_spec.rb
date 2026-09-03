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

  # One round, prose only, no calls — the shape a reply takes when the model
  # writes about doing something instead of doing it.
  def says!(body, text)
    inbound = convo.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: body)
    Buddy::GPT::Turn.run!(inbound, client: FakeBuddyClient.new([{ text: text }, { text: text }]))
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

    # Prod 2183: "log cup water" against a saved **water cup** that marks three
    # waters logged exactly one. Every other branch of the name match is a
    # substring test, and a transposition walks straight past all of them.
    it "runs the saved one when the words come back in a different order" do
      create(:chore, created_by_user: user, chore_household: household, name: "8oz Water")
      routine!("water cup", [BuddyRoutine.step(:complete_chore, { chore: "8oz Water", count: 3 })])

      turn!("log cup water", [run_call("cup water")])

      expect(ChoreCompletion.where(user_id: user.id).count).to eq(3)
    end

    it "says so rather than running something else when nothing matches" do
      routine!("Nightly", [tell_step("night")])

      client = turn!("do the morning thing", [run_call("Morning Sweep")])

      expect(chips).to be_empty
      # Across every call, not the last one: a turn that runs nothing gets a
      # second attempt built fresh from the thread. See Turn#start_over?.
      output = JSON.parse(client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["status"]).to eq("failed")
      expect(output["error"]).to match(/no routine called/i)
    end

    it "doesn't reach for a routine that merely shares a word with the request" do
      routine!("water cup", [tell_step("night")])

      client = turn!("prep the printer", [run_call("prep printer")])

      expect(chips).to be_empty
      output = JSON.parse(client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }.last[:output])
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

  # ---- the message that IS the name ----------------------------------------

  # The name was already in the prompt under "Routines they've saved", and
  # matching it was left entirely to the model reading it. Prod 3392: "Good
  # night", against a saved **good night**, got a warm goodnight and nothing
  # run. The follow-up got the monitors dark by hand and the other step never
  # ran that night at all, which is the shape of the whole problem - half a
  # routine looks like a working one.
  describe "a message that is nothing but a routine's name" do
    it "runs it even when the turn only talks" do
      routine!("good night", [tell_step("dark"), tell_step("monitors off")])

      says!("Good night", "Good night! Sleep well. 💙")

      expect(told).to eq(["dark", "monitors off"])
    end

    it "counts the run the same as one the model asked for" do
      routine = routine!("good night", [tell_step("dark")])

      says!("Good night", "Night!")

      expect(routine.reload.run_count).to eq(1)
      expect(routine.last_run_at).to be_present
    end

    # The words are the good part of that reply and there's nothing wrong with
    # them - what was missing was underneath.
    it "keeps what it said rather than replacing it with a receipt" do
      routine!("good night", [tell_step("dark")])

      says!("Good night", "Good night! Sleep well. 💙")

      expect(convo.byte_messages.where(direction: :inbound).order(:id).first.body).to include("Sleep well")
    end

    # Doing SOME of it by hand is the failure that hides: a chip appears, the
    # reply sounds right, and the step nobody thought of is the one that
    # mattered. The saved sequence replaces the improvisation outright.
    it "replaces steps the turn improvised instead" do
      routine!("good night", [tell_step("dark"), tell_step("monitors off")])

      turn!("Good night", [{ name: :message_partner, call_id: "m1", arguments: { "to" => her, "message" => "by hand" } }])

      expect(told).to eq(["dark", "monitors off"])
    end

    it "does not count it twice when the model called it properly" do
      routine = routine!("good night", [tell_step("dark")])

      turn!("Good night", [run_call("good night")])

      expect(routine.reload.run_count).to eq(1)
    end

    # Every word that isn't the name is content the name doesn't account for,
    # and this runs a whole saved sequence off no decision by anybody.
    it "stays out of a sentence that merely contains the name" do
      routine!("good night", [tell_step("dark")])

      says!("have a good night, and remind me about the bins", "You got it.")

      expect(told).to be_empty
    end

    it "stays out of a question about the routine" do
      routine!("good night", [tell_step("dark")])

      says!("what does my good night routine do", "It kills the lights.")

      expect(told).to be_empty
    end

    it "reads through the filler people wrap a name in" do
      routine!("good night", [tell_step("dark")])

      says!("run my good night please", "On it.")

      expect(told).to eq(["dark"])
    end

    it "leaves a disabled one switched off" do
      routine!("good night", [tell_step("dark")], enabled: false)

      says!("Good night", "Night!")

      expect(told).to be_empty
    end
  end

  # ---- a step that stopped pointing anywhere -------------------------------

  # Saving only proves a routine could run on the day it was saved. Steps hold
  # NAMES and re-resolve every run, so a renamed chore turns one into a marker
  # ProposalBuilder drops without a word - and nobody re-reads a saved sequence,
  # so it fails identically every time and looks like it ran. Routines stored
  # before save-time resolution shipped never had the check at all.
  describe "a routine that can't run any more" do
    let!(:rotten) {
      routine!("Water Cup", [BuddyRoutine.step(:complete_chore, { chore: "Drink Water", count: 3 })])
    }

    it "tells the model why, instead of running none of it quietly" do
      client = turn!("water cup", [run_call("Water Cup")])

      output = JSON.parse(client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["status"]).to eq("failed")
      expect(output["error"]).to match(/no chore matching/i)
    end

    it "records nothing at all" do
      turn!("water cup", [run_call("Water Cup")])

      expect(ChoreCompletion.where(user_id: user.id)).to be_empty
      expect(rotten.reload.run_count).to eq(0)
    end

    # Saying the name outright is the one path that reaches the steps without
    # the model calling run_routine, so it's the one path that could walk
    # around this check. The guarantee that a named routine runs must not step
    # over the guarantee that a broken one doesn't run in pieces.
    it "is not forced into running by the person saying its name" do
      create(:chore, created_by_user: user, chore_household: household, name: "8oz Water")
      rotten.update!(steps: [
        BuddyRoutine.step(:message_partner, { to: her, message: "drinking" }),
        BuddyRoutine.step(:complete_chore, { chore: "Drink Water" }),
      ])

      says!("water cup", "Done!")

      expect(told).to be_empty
      expect(rotten.reload.run_count).to eq(0)
    end

    # All or nothing: the half that ran would look like the whole thing worked.
    it "holds back the steps that WOULD have worked" do
      create(:chore, created_by_user: user, chore_household: household, name: "8oz Water")
      rotten.update!(steps: [
        BuddyRoutine.step(:message_partner, { to: her, message: "drinking" }),
        BuddyRoutine.step(:complete_chore, { chore: "Drink Water" }),
      ])

      turn!("water cup", [run_call("Water Cup")])

      expect(told).to be_empty
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

      output = JSON.parse(client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }.last[:output])
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

    # Prod 1362: "it's supposed to complete the chore 3 times, and there
    # shouldn't be an event in there" describes the SAVED steps. Re-saving is
    # what fixes it; running the steps live does actions nobody asked for and
    # leaves the routine wrong.
    it "fixes a routine by re-saving it, leaving nothing behind from the old one" do
      create(:chore, created_by_user: user, chore_household: household, name: "8oz Water")
      routine!("Water Cup", [
        BuddyRoutine.step(:complete_chore, { chore: "8oz Water", count: 3 }),
        BuddyRoutine.step(:log_event, { name: "Water", count: 3 }),
      ])

      turn!("there shouldn't be an event in that one", [
        save_call("Water Cup", [{ tool_name: "complete_chore", payload: { chore: "8oz Water", count: 3 } }]),
      ])

      steps = user.buddy_routines.find_by(name: "Water Cup").steps
      expect(steps.map { |s| s["tool_name"] }).to eq(["complete_chore"])
      expect(ActionEvent.where(user_id: user.id)).to be_empty
    end

    # Prod 1345: the model wrote its step flat, the payload came through empty,
    # and it came back "missing required arg :name" about a step whose name was
    # sitting right there. The routine was lost and the reply claimed it saved.
    it "takes a step written flat, not just one wrapped in a payload" do
      turn!("save the preheat task as prep my printer", [
        save_call("Prep", [{ tool_name: "message_partner", to: her, message: "flat" }]),
      ])

      routine = user.buddy_routines.find_by(name: "Prep")
      expect(routine.steps.first["payload"]).to include("to" => her, "message" => "flat")
    end

    it "doesn't mistake the tool's own name for one of its arguments" do
      client = turn!("save this", [save_call("Nope", [{ name: "message_partner" }])])

      expect(user.buddy_routines.count).to eq(0)
      output = JSON.parse(client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["error"]).to match(/missing required arg/i)
    end

    # Prod: "water cup" saved as complete_chore(chore: "Drink Water") against a
    # household with no such chore. The arguments were the right SHAPE, so it
    # stored happily — and then failed silently on every run. Shape is not the
    # question; whether it points at anything is.
    it "refuses a step aimed at something that doesn't exist" do
      client = turn!("save that as water cup", [
        save_call("Water Cup", [{ tool_name: "complete_chore", payload: { chore: "Drink Water", count: 3 } }]),
      ])

      expect(user.buddy_routines.count).to eq(0)
      output = JSON.parse(client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["error"]).to match(/no chore matching/i)
    end

    it "saves the same step once the chore is real" do
      create(:chore, created_by_user: user, chore_household: household, name: "8oz Water")

      turn!("save that as water cup", [
        save_call("Water Cup", [{ tool_name: "complete_chore", payload: { chore: "8oz Water", count: 3 } }]),
      ])

      steps = user.buddy_routines.find_by(name: "Water Cup").steps
      expect(steps.first["payload"]).to include("chore" => "8oz Water", "count" => 3)
    end

    # Resolution is a check, not a rewrite: the step keeps the NAME so every run
    # re-resolves it, rather than freezing today's id.
    it "keeps the name rather than the id confirm resolved it to" do
      create(:chore, created_by_user: user, chore_household: household, name: "8oz Water")

      turn!("save that", [
        save_call("Water Cup", [{ tool_name: "complete_chore", payload: { chore: "8oz water" } }]),
      ])

      payload = user.buddy_routines.find_by(name: "Water Cup").steps.first["payload"]
      expect(payload).to include("chore" => "8oz water")
      expect(payload.keys).not_to include("chore_id")
    end

    it "refuses a step whose tool doesn't exist instead of saving something broken" do
      client = turn!("save this", [
        save_call("Nope", [{ tool_name: "launch_rocket", payload: {} }]),
      ])

      expect(user.buddy_routines.count).to eq(0)
      output = JSON.parse(client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["error"]).to match(/no tool called/i)
    end

    it "refuses a step that's missing a required argument" do
      client = turn!("save this", [
        save_call("Nope", [{ tool_name: "message_partner", payload: { to: her } }]),
      ])

      expect(user.buddy_routines.count).to eq(0)
      output = JSON.parse(client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }.last[:output])
      expect(output["error"]).to match(/missing required arg/i)
    end

    it "keeps a call that only means something once out of a routine" do
      client = turn!("save this", [
        save_call("Nope", [{ tool_name: "undo", payload: {} }]),
      ])

      expect(user.buddy_routines.count).to eq(0)
      output = JSON.parse(client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }.last[:output])
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

    # Three waters collapse into ONE row that runs three times, and the three
    # lives on the row - `args`, which is what a capture reads, still holds the
    # first call's payload and says one. Saved from that, "cash in three
    # waters" became a button that cashes in one.
    it "keeps the count when the calls it saves were collapsed into one row" do
      create(:chore, created_by_user: user, chore_household: household, name: "8oz Water")
      turn!("drank three waters", [
        { name: :complete_chore, call_id: "a", arguments: { "chore" => "8oz Water" } },
        { name: :complete_chore, call_id: "b", arguments: { "chore" => "8oz Water" } },
        { name: :complete_chore, call_id: "c", arguments: { "chore" => "8oz Water" } },
      ])

      turn!("save that as water cup", [capture_call("Water Cup", 1)])

      payload = user.buddy_routines.find_by(name: "Water Cup").steps.first["payload"]
      expect(payload).to include("chore" => "8oz Water", "count" => 3)
    end

    it "runs that saved copy three times, the way it was captured" do
      create(:chore, created_by_user: user, chore_household: household, name: "8oz Water")
      turn!("drank three waters", [
        { name: :complete_chore, call_id: "a", arguments: { "chore" => "8oz Water" } },
        { name: :complete_chore, call_id: "b", arguments: { "chore" => "8oz Water" } },
        { name: :complete_chore, call_id: "c", arguments: { "chore" => "8oz Water" } },
      ])
      turn!("save that as water cup", [capture_call("Water Cup", 1)])

      turn!("water cup", [run_call("Water Cup")])

      expect(ChoreCompletion.where(user_id: user.id).count).to eq(6)
    end

    it "says it has nothing to save rather than inventing steps" do
      client = turn!("save that", [capture_call("Nightly", 2)])

      expect(user.buddy_routines.count).to eq(0)
      output = JSON.parse(client.calls.flat_map(&:input).select { |i| i[:type] == :function_call_output }.last[:output])
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

  # ---- a save that didn't take can't read as one that did -------------------

  # Prod 1345-1348. save_routine failed on a malformed step, run_routine failed
  # on the routine that was therefore never there, and BOTH replies announced
  # success - so the person tried to run a thing that had never been saved and
  # got "Yesss, running prep my printer now" with nothing behind it.
  describe "when the call didn't land" do
    def reply
      convo.byte_messages.where(direction: :inbound).order(:id).last
    end

    it "retracts a claim that a routine was saved when nothing was" do
      turn!(
        "save that as prep my printer",
        [{ name: :save_routine, call_id: "s1", arguments: { "name" => "Prep", "steps" => "not json" } }],
        text: "Saved as **prep my printer**. It now runs the preheat task.",
      )

      expect(user.buddy_routines.count).to eq(0)
      expect(reply.body).to eq(Buddy::GPT::Turn::SILENT_BODY)
      expect(reply.metadata["retracted_claim"]).to be(true)
    end

    it "retracts a claim that a routine is running when it doesn't exist" do
      turn!("prep my printer", [run_call("Prep")], text: "Yesss, running **prep my printer** now.")

      expect(reply.body).to eq(Buddy::GPT::Turn::SILENT_BODY)
      expect(reply.metadata["retracted_claim"]).to be(true)
    end

    it "leaves an honest offer alone" do
      turn!("prep my printer", [run_call("Prep")], text: "I can save that as a routine if you want.")

      expect(reply.body).to eq("I can save that as a routine if you want.")
    end

    # Prod 1374 and 1379: "I counted drank water cup as 8oz Water" and "I'm
    # counting it as 3", both with no tool call behind them. They had to point
    # it out — "I don't see any tool uses".
    it "retracts a count nothing recorded" do
      says!("drank water cup", "Yesss, I counted **drank water cup** as **8oz Water**.")

      expect(reply.body).to eq(Buddy::GPT::Turn::SILENT_BODY)
      expect(reply.metadata["retracted_claim"]).to be(true)
    end

    it "leaves an offer to count alone" do
      says!("drank water cup", "Want me to count that as 3?")

      expect(reply.body).to eq("Want me to count that as 3?")
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

  # The names have to be in the PROMPT. Behind get_context they were unreachable
  # in practice: the rules say don't fetch that section on the chance a phrase
  # might be a routine (correctly - almost nothing is), which left a routine
  # recognisable only to someone who said the word "routine" out loud.
  describe "the names in the prompt" do
    def prompt = Buddy::Personality.for(user, conversation: convo)

    it "lists every saved name, with what it's for" do
      routine!("water cup", [tell_step("night")], description: "Three waters")

      expect(prompt).to include("## Routines they've saved", "water cup", "Three waters")
    end

    # The rules bullet and run_routine's description both name this section, so
    # a heading carrying the person's name couldn't be quoted by either.
    it "heads the section with the same words the rules point at" do
      routine!("water cup", [tell_step("night")])

      expect(prompt.scan("Routines they've saved").length).to be >= 2
    end

    it "leaves a switched-off one out, so it can't be offered" do
      routine!("Off", [tell_step("night")], enabled: false)

      expect(prompt).not_to include("## Routines they've saved")
    end

    it "costs nothing for the people who never saved one" do
      expect(Buddy::Personality.routines_block(user)).to be_nil
    end

    it "still tells Buddy not to go hunting for one" do
      routine!("water cup", [tell_step("night")])

      expect(prompt).to match(/if it isn't here, it isn't one/i)
    end
  end
end
