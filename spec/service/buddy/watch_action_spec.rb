require "rails_helper"

# A watch that DOES something instead of saying something.
#
# The load-bearing property is that no model sits between the sensor and the
# light: the task is resolved when the watch is SET, so firing it is a Jil
# trigger and a receipt, at 2am, with nothing to think about.
RSpec.describe "Buddy watch actions" do
  let(:user)   { create(:user) }
  # `hass-sensor` isn't in KNOWN_SCOPES; it's recognised because a real task
  # listens on it. Mirrors how the house sensors actually work.
  let!(:sensor_task) {
    Task.create!(
      user: user, name: "Doggy Door Log", listener: "hass-sensor:device_name::doggy_door",
      code: "", enabled: true, buddy_enabled: true
    )
  }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  let!(:quiet) {
    Task.create!(
      user: user, name: "Whisper Quiet", listener: "whisper-quiet", description: "Drops the volume",
      code: "", enabled: true, buddy_enabled: true
    )
  }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(::Jil).to receive(:trigger).and_return(true)
    Rails.cache.delete("jil:wired_scopes:#{user.id}")
  end

  def run(payload)
    markers = [{ tool_name: :remind_when, payload: payload, span: [0, 0] }]
    Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
  end

  def doorbell(**extra)
    {
      text:        "quiet the house",
      trigger:     "custom",
      listener:    "hass-sensor:device_name::doggy_door",
      when_phrase: "when the doggy door opens",
      **extra,
    }
  end

  describe "setting one" do
    it "makes an action watch that names the task and the delay" do
      expect { run(doorbell(run: "Whisper Quiet", delay: 10)) }.to change(BuddyWatch, :count).by(1)

      watch = BuddyWatch.last
      expect(watch.kind).to eq("action")
      expect(watch.run_scope).to eq("whisper-quiet")
      expect(watch.run_task_name).to eq("Whisper Quiet")
      expect(watch.run_delay).to eq(10)
    end

    it "still makes an ordinary reminder watch when no task is named" do
      run(doorbell)

      expect(BuddyWatch.last.kind).to eq("prompt")
      expect(BuddyWatch.last.run_delay).to eq(0)
    end

    it "refuses a task name that matches nothing rather than wiring up a dud" do
      run(doorbell(run: "Nonexistent Thing"))

      expect(BuddyWatch.count).to eq(0)
    end

    # Nothing builds a payload when a sensor trips, so a filtered listener would
    # be set up and then never fire — the exact failure a watch must not have.
    it "refuses a task whose listener needs data" do
      Task.create!(
        user: user, name: "Categorize", listener: "event:add name::Transaction",
        code: "", enabled: true, buddy_enabled: true
      )

      run(doorbell(run: "Categorize"))

      expect(BuddyWatch.count).to eq(0)
    end

    it "does not both tell someone and run something" do
      run(doorbell(run: "Whisper Quiet", notify: "Chelsea"))

      expect(BuddyWatch.count).to eq(0)
    end

    it "caps an absurd delay rather than holding a job for an hour" do
      run(doorbell(run: "Whisper Quiet", delay: 99_999))

      expect(BuddyWatch.last.run_delay).to eq(BuddyWatch::MAX_ACTION_DELAY)
    end
  end

  describe "firing one" do
    def watch!(delay:)
      run(doorbell(run: "Whisper Quiet", delay: delay))
      BuddyWatch.last
    end

    it "fires the task straight away when there's no delay, leaving only a receipt", :aggregate_failures do
      w = watch!(delay: 0)

      Buddy::WatchMatcher.fire!(w)

      expect(::Jil).to have_received(:trigger).with(user, :"whisper-quiet", {}, hash_including(auth: :buddy))
      chip = convo.byte_messages.where("metadata->>'source' = 'watch'").last
      expect(chip.body).to include("Whisper Quiet")
      expect(chip.metadata["kind"]).to eq("buddy_activity")
      expect(convo.byte_messages.where("metadata->>'kind' = 'buddy_trigger'")).to be_empty
    end

    it "hands a delayed one to a job, which runs it when it lands" do
      w = watch!(delay: 10)

      Sidekiq::Testing.fake! {
        BuddyWatchActionWorker.clear
        Buddy::WatchMatcher.fire!(w)

        expect(BuddyWatchActionWorker.jobs.size).to eq(1)
      }
      expect(::Jil).not_to have_received(:trigger).with(user, :"whisper-quiet", any_args)

      BuddyWatchActionWorker.new.perform(w.id)

      expect(::Jil).to have_received(:trigger).with(user, :"whisper-quiet", {}, hash_including(auth: :buddy))
    end

    # Ten seconds is short, but "cancel that" inside the window is exactly when
    # someone means it, and a cancelled watch firing anyway is worse than late.
    it "doesn't run it if the watch was cancelled inside the window" do
      w = watch!(delay: 10)
      w.update!(cancelled_at: Time.current)

      BuddyWatchActionWorker.new.perform(w.id)

      expect(::Jil).not_to have_received(:trigger).with(user, :"whisper-quiet", any_args)
    end
  end

  # `run` can name a Jil function and carry its arguments.
  describe "running a function with its arguments" do
    let!(:navigate) {
      Task.create!(
        user: user, name: "Tesla Navigate", buddy_enabled: true, enabled: true,
        listener: 'function("Destination" TAB String)::String', code: ""
      )
    }

    def depart_watch!(**extra)
      run(doorbell(text: "Heading to Petsmart.", run: "Tesla Navigate", run_args: { destination: "Petsmart" }, **extra))
      BuddyWatch.last
    end

    it "stores the call, arguments and all" do
      w = depart_watch!

      expect(w.kind).to eq("action")
      expect(w.run_task_name).to eq("Tesla Navigate")
      expect(w.run_calls).to eq(
        [{ tool_name: :call_jil_function, payload: { name: "Tesla Navigate", destination: "Petsmart" } }],
      )
    end

    it "refuses a function that matches nothing" do
      run(doorbell(run: "Teleport", run_args: { destination: "Petsmart" }))

      expect(BuddyWatch.count).to eq(0)
    end

    it "runs the call when the watch fires, with no model turn" do
      w = depart_watch!
      ran = nil
      allow(Buddy::ProposalBuilder).to receive(:run_markers!) { |args| ran = args }

      Buddy::WatchMatcher.fire!(w)

      expect(ran[:markers]).to eq(w.run_calls)
      expect(ran[:body]).to eq("Heading to Petsmart.")
      expect(::Jil).not_to have_received(:trigger)
    end

    it "reaches the function with the destination it was set with" do
      w = depart_watch!
      called = nil
      allow_any_instance_of(Task).to receive(:execute) { |task, *args, **kw|
        called = [task.name, args, kw]
        nil
      }

      Buddy::WatchMatcher.fire!(w)

      expect(called&.first).to eq("Tesla Navigate")
      expect(called.inspect).to include("Petsmart")
    end

    it "waits out a delay the same way a trigger does" do
      w = depart_watch!(delay: 10)
      allow(Buddy::ProposalBuilder).to receive(:run_markers!)

      Sidekiq::Testing.fake! {
        BuddyWatchActionWorker.clear
        Buddy::WatchMatcher.fire!(w)

        expect(BuddyWatchActionWorker.jobs.size).to eq(1)
      }
      expect(Buddy::ProposalBuilder).not_to have_received(:run_markers!)

      BuddyWatchActionWorker.new.perform(w.id)

      expect(Buddy::ProposalBuilder).to have_received(:run_markers!)
    end
  end

  # A listener on the front of a whole chain: a saved routine, or steps written
  # for this one watch, run with no model turn when the condition hits.
  describe "running a sequence" do
    let(:steps_json) {
      [
        { tool_name: "set_timer", payload: { minutes: 2, then_continue: true } },
        { tool_name: "run_jil_task", payload: { name: "Whisper Quiet" } },
      ].to_json
    }
    let!(:routine) {
      user.buddy_routines.create!(name: "Wind Down", steps: [BuddyRoutine.step(:run_jil_task, { name: "Whisper Quiet" })])
    }

    it "stores steps written for the watch, checked the way a routine's are" do
      run(doorbell(text: "Winding down.", steps: steps_json))

      w = BuddyWatch.last
      expect(w.kind).to eq("action")
      expect(w.run_steps.pluck("tool_name")).to eq(["set_timer", "run_jil_task"])
      expect(w.run_task_name).to include("wait 2 min", "run jil task: Whisper Quiet")
    end

    it "refuses a step that can't run, before anything is armed" do
      run(doorbell(steps: [{ tool_name: "run_jil_task", payload: { name: "Teleporter" } }].to_json))

      expect(BuddyWatch.count).to eq(0)
    end

    it "refuses steps alongside a single task" do
      run(doorbell(run: "Whisper Quiet", steps: steps_json))

      expect(BuddyWatch.count).to eq(0)
    end

    it "plays the steps through the routine runner when it fires" do
      run(doorbell(text: "Winding down.", steps: steps_json))
      w = BuddyWatch.last
      ran = nil
      allow(Buddy::ProposalBuilder).to receive(:run_markers!) { |args| ran = args }

      Buddy::WatchMatcher.fire!(w)

      expect(ran[:markers].pluck(:tool_name)).to eq([:set_timer, :run_jil_task])
      expect(ran[:body]).to eq("Winding down.")
      expect(w.reload.fired_at).to be_present
    end

    it "names a saved routine and runs whatever it holds when it fires" do
      run(doorbell(routine: "wind down"))
      w = BuddyWatch.last
      expect(w.run_routine_id).to eq(routine.id)
      expect(w.run_task_name).to eq("Wind Down")

      allow(Buddy::Routines).to receive(:run!)
      Buddy::WatchMatcher.fire!(w)

      expect(Buddy::Routines).to have_received(:run!).with(routine, conversation: convo)
    end

    it "says so instead of running a routine that has been switched off" do
      run(doorbell(routine: "Wind Down"))
      w = BuddyWatch.last
      routine.update!(enabled: false)
      allow(Buddy::Routines).to receive(:run!)

      Buddy::WatchMatcher.fire!(w)

      expect(Buddy::Routines).not_to have_received(:run!)
      expect(convo.byte_messages.last.body).to include("Wind Down")
    end

    it "refuses a routine that doesn't exist" do
      run(doorbell(routine: "Nope"))

      expect(BuddyWatch.count).to eq(0)
    end
  end
end
