require "rails_helper"

# An alarm is a watch that RINGS, as opposed to one that posts a line.
#
# Prod Aug 10: "set an alarm for the next time the washer finishes" was answered
# with a one-second `timer` watch, because that was the only shape that made a
# noise. Every surface then named the mechanism instead of the thing — the
# receipt said "will start a 1 second timer", the reminders list said "starts a
# 1 sec timer", and what actually went off announced itself as a timer expiring.
RSpec.describe "Buddy alarms" do
  let(:user) { create(:user) }
  # A real task listening on the scope is what makes it watchable at all
  # (Jil::ListenerMatch#wired_scopes) — the house sensors appear nowhere else.
  let!(:hass_task) {
    Task.create!(
      user: user, name: "Hass Triggers", listener: "hass-trigger",
      code: "", enabled: true, buddy_enabled: true
    )
  }
  let!(:convo) { ByteConversation.create!(user: user, mode: :buddy, name: "Buddy", last_message_at: Time.current) }
  let(:msg)    { convo.byte_messages.create!(user: user, direction: :inbound, state: :delivered, body: "ok") }

  # An alarm's countdown is one second long and the suite runs Sidekiq inline,
  # so without this the fire worker goes off mid-example and every assertion
  # about what the alarm SAYS is really an assertion about how fast the spec ran.
  around { |ex| Sidekiq::Testing.fake! { ex.run } }

  before do
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
    Rails.cache.delete("jil:wired_scopes:#{user.id}")
    TimerFireWorker.clear
  end

  def run(payload, tool: :alarm)
    markers = [{ tool_name: tool, payload: payload, span: [0, 0] }]
    Buddy::ProposalBuilder.create(user: user, byte_message: msg, markers: markers)
  end

  def washer(**extra)
    {
      label:       "Washer's done",
      trigger:     "custom",
      listener:    "hass-trigger:device_name::Washer type::stop",
      when_phrase: "when the washer stops",
      **extra,
    }
  end

  # Verbatim shape of what Home Assistant posts when the washer stops.
  def washer_stopped
    {
      "type"        => "stop",
      "battery"     => "100.0",
      "device_name" => "Washer",
      "entity_id"   => "input_boolean.washer_running",
    }
  end

  # A clock time and a duration need no watch at all — the countdown IS the
  # alarm. What makes it one rather than a timer is the flag, which is what
  # decides whether the thing that goes off says "Wake up" or "Time's up".
  describe "on the clock" do
    it "sets one for a stretch of time" do
      expect { run({ label: "Wake up", seconds: 1200 }) }.not_to change(BuddyWatch, :count)

      timer = user.timers.order(:id).last
      expect(timer.name).to eq("Wake up")
      expect(timer.duration_ms).to eq(1_200_000)
      expect(Buddy::Alarms.alarm?(timer)).to be(true)
    end

    it "sets one for a wall-clock moment" do
      at = 3.hours.from_now

      run({ label: "Leave for the airport", at: at.iso8601 })

      timer = user.timers.order(:id).last
      expect(timer.end_at).to be_within(2.seconds).of(at)
    end

    it "measures to the moment, not from when the turn finished" do
      at = 90.minutes.from_now
      # The message that asked came in a minute ago; a duration measured from
      # `now` would ring a minute early.
      convo.byte_messages.where(direction: :outbound).delete_all
      convo.byte_messages.create!(
        user: user, direction: :outbound, state: :delivered,
        body: "alarm at 9", created_at: 1.minute.ago
      )

      run({ label: "Nine", at: at.iso8601 })

      expect(user.timers.order(:id).last.end_at).to be_within(2.seconds).of(at)
    end

    it "says when it will go off rather than how long the countdown is" do
      run({ label: "Wake up", seconds: 1200 })

      chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
      expect(chip.body).to include("alarm")
      expect(chip.body).not_to include("timer")
    end

    it "refuses a time that has already gone" do
      expect { run({ label: "Too late", at: 5.minutes.ago.iso8601 }) }.not_to(change { user.timers.count })
    end

    it "refuses one further out than a countdown reaches, rather than ringing on the wrong day" do
      expect { run({ label: "Next week", at: 3.days.from_now.iso8601 }) }.not_to(change { user.timers.count })
    end

    it "refuses a time AND a condition at once" do
      expect { run(washer(seconds: 60)) }.not_to change(BuddyWatch, :count)
    end

    it "refuses an alarm with neither" do
      expect { run({ label: "When?" }) }.not_to(change { user.timers.count })
    end

    it "goes off saying what it was set for" do
      run({ label: "Wake up", seconds: 1200 })

      Buddy::Timers.on_fired(user.timers.order(:id).last)

      said = convo.byte_messages.where(direction: :inbound).order(:created_at).last
      expect(said.body).to include("Wake up")
      expect(said.body).not_to include("Time's up")
      expect(said.metadata["source"]).to eq("alarm")
    end

    it "can be stopped with the ordinary timer controls" do
      run({ label: "Wake up", seconds: 1200 })
      timer = user.timers.order(:id).last

      expect(Buddy::Timers.buddy_timer?(user, timer)).to be(true)
      expect(Buddy::Timers.live_for(user)).to include(timer)
    end
  end

  describe "setting one" do
    it "makes an alarm watch carrying what it's for" do
      expect { run(washer) }.to change(BuddyWatch, :count).by(1)

      watch = BuddyWatch.last
      expect(watch.kind).to eq("alarm")
      expect(watch).to be_alarm
      expect(watch.body).to eq("Washer's done")
      expect(watch.trigger_scope).to eq("hass-trigger")
      expect(watch.one_shot).to be(true)
    end

    it "says it will sound an alarm, not that it will remind them or set a timer" do
      run(washer)

      chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
      expect(chip.body).to include("alarm").and(include("when the washer stops"))
      expect(chip.body).not_to include("remind you")
      expect(chip.body).not_to include("timer")
    end

    it "shows the listener underneath so a wrong one can be caught now" do
      run(washer)

      chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
      expect(chip.body).to include("hass-trigger:device_name::Washer type::stop")
    end

    it "stays armed when they want it every time" do
      run(washer(repeat: true))

      expect(BuddyWatch.last.one_shot).to be(false)
      expect(BuddyWatch.last.metadata["human_when"]).to eq("every time the washer stops")
    end

    it "stops on its own when they bounded it" do
      run(washer(repeat: true, expires: "today"))

      expect(BuddyWatch.last.expires_at).to be_present
    end

    it "refuses a listener that could never fire rather than saving a silent alarm" do
      expect {
        run(washer(listener: "definitelynotascope:action:stop", when_phrase: "when the thing stops"))
      }.not_to change(BuddyWatch, :count)
    end

    it "refuses a custom condition with no listener at all" do
      expect { run(washer(listener: nil)) }.not_to change(BuddyWatch, :count)
    end
  end

  describe "when the condition happens" do
    let!(:watch) {
      run(washer)
      BuddyWatch.last
    }

    it "starts the countdown that does the ringing" do
      expect {
        Buddy::WatchMatcher.fire!(watch, washer_stopped)
      }.to change { user.timers.count }.by(1)
    end

    it "names that countdown what the alarm is for" do
      Buddy::WatchMatcher.fire!(watch, washer_stopped)

      expect(user.timers.order(:id).last.name).to eq("Washer's done")
    end

    it "marks that countdown as an alarm, so what goes off knows what it is" do
      Buddy::WatchMatcher.fire!(watch, washer_stopped)

      expect(Buddy::Alarms.alarm?(user.timers.order(:id).last)).to be(true)
    end

    it "says nothing yet — the alarm speaks when it goes off" do
      said = -> { convo.byte_messages.where("metadata->>'source' = 'watch'").count }

      expect { Buddy::WatchMatcher.fire!(watch, washer_stopped) }.not_to change(said, :call)
    end

    it "does not fire on the washer STARTING" do
      expect {
        Buddy::WatchMatcher.dispatch(user, "hass-trigger", washer_stopped.merge("type" => "start"))
      }.not_to(change { user.timers.count })
    end

    it "does not fire for a different appliance" do
      expect {
        Buddy::WatchMatcher.dispatch(user, "hass-trigger", washer_stopped.merge("device_name" => "Dryer"))
      }.not_to(change { user.timers.count })
    end

    it "fires off the real trigger bus" do
      expect {
        Buddy::WatchMatcher.dispatch(user, "hass-trigger", washer_stopped)
      }.to change { user.timers.count }.by(1)
    end
  end

  describe "when it goes off" do
    let(:timer) {
      run(washer)
      Buddy::WatchMatcher.fire!(BuddyWatch.last, washer_stopped)
      user.timers.order(:id).last
    }

    it "says the thing it was set for, not that a timer finished" do
      Buddy::Timers.on_fired(timer)

      said = convo.byte_messages.where(direction: :inbound).order(:created_at).last
      expect(said.body).to include("Washer's done")
      expect(said.body).not_to include("Time's up")
      expect(said.metadata["source"]).to eq("alarm")
    end

    it "pushes, so it lands even when they're away from the thread" do
      Buddy::Timers.on_fired(timer)

      expect(WebPushNotifications).to have_received(:send_to_byte)
    end

    it "leaves an ordinary timer saying what it always said" do
      plain = Buddy::Timers.create!(user: user, seconds: 60, label: "Pasta")

      Buddy::Timers.on_fired(plain)

      said = convo.byte_messages.where(direction: :inbound).order(:created_at).last
      expect(said.body).to include("Time's up").and(include("Pasta"))
      expect(said.metadata["source"]).to eq("timer")
    end
  end

  it "says what it does when Buddy looks at what it's watching" do
    run(washer)

    listed = Buddy::Context.send(:active_watches, convo)

    expect(listed.first[:does]).to eq("sounds an alarm")
  end

  # The shared half. remind_when and alarm resolve conditions through the same
  # code precisely so an arrival watch and an arrival alarm can't disagree about
  # where Costco is.
  describe "sharing conditions with remind_when" do
    it "resolves a named trigger the same way for both" do
      run(washer)
      alarm_watch = BuddyWatch.last

      run({ text: "put it away", trigger: "custom", listener: washer[:listener], when_phrase: "when the washer stops" }, tool: :remind_when)
      reminder = BuddyWatch.last

      expect(alarm_watch.trigger_scope).to eq(reminder.trigger_scope)
      expect(alarm_watch.listener).to eq(reminder.listener)
      expect(alarm_watch.kind).to eq("alarm")
      expect(reminder.kind).to eq("prompt")
    end
  end
end
