require "rails_helper"

# A watch that DOES something instead of saying something.
#
# Prod Aug 3: "Trigger whisper-quiet 10 seconds after the next time the doggy
# door sensor gets triggered" got "I can watch the doggy door sensor, but I
# can't make it wait 10 seconds after the trigger on its own." True at the time
# - remind_when only ever delivered a nudge, and had no delay.
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

    it "says what it will do, not that it will remind them" do
      run(doorbell(run: "Whisper Quiet", delay: 10))

      chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
      expect(chip.body).to include("Whisper Quiet", "10s after")
      expect(chip.body).not_to include("remind you")
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

  # The refusal was the actual failure — the plumbing didn't exist, but nothing
  # would have used it either.
  it "tells the model this is possible, using the request that got refused" do
    prompt = Buddy::Personality.for(user, conversation: convo)

    expect(prompt).to include("A watch can DO something, and it can wait first")
    expect(prompt).to include("`run`", "`delay`")
  end

  describe "firing one" do
    def watch!(delay:)
      run(doorbell(run: "Whisper Quiet", delay: delay))
      BuddyWatch.last
    end

    it "fires the task straight away when there's no delay" do
      w = watch!(delay: 0)

      Buddy::WatchMatcher.fire!(w)

      expect(::Jil).to have_received(:trigger).with(user, :"whisper-quiet", {}, hash_including(auth: :buddy))
    end

    it "hands a delayed one to a job instead of sleeping on the trigger" do
      w = watch!(delay: 10)

      Sidekiq::Testing.fake! {
        BuddyWatchActionWorker.clear
        Buddy::WatchMatcher.fire!(w)

        expect(BuddyWatchActionWorker.jobs.size).to eq(1)
      }
      expect(::Jil).not_to have_received(:trigger).with(user, :"whisper-quiet", any_args)
    end

    it "runs it when the job lands" do
      w = watch!(delay: 10)

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

    it "leaves a receipt so a silent automation is still traceable" do
      w = watch!(delay: 0)

      Buddy::WatchMatcher.fire!(w)

      chip = convo.byte_messages.where("metadata->>'source' = 'watch'").last
      expect(chip.body).to include("Whisper Quiet")
      expect(chip.metadata["kind"]).to eq("buddy_activity")
    end

    it "says nothing to the person beyond that receipt" do
      w = watch!(delay: 0)

      Buddy::WatchMatcher.fire!(w)

      expect(convo.byte_messages.where("metadata->>'kind' = 'buddy_trigger'")).to be_empty
      expect(convo.byte_messages.where("metadata->>'source' = 'watch'").where("body LIKE '%Reminder%'")).to be_empty
    end
  end
end
