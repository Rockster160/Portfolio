require "rails_helper"

RSpec.describe "Buddy alarms" do
  # An alarm is a watch that RINGS, as opposed to one that posts a line.
  describe "alarms" do
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
    # so without this the fire worker goes off mid-example.
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

    # The shape of what Home Assistant posts when the washer stops.
    def washer_stopped
      {
        "type"        => "stop",
        "battery"     => "100.0",
        "device_name" => "Washer",
        "entity_id"   => "input_boolean.washer_running",
      }
    end

    def last_said
      convo.byte_messages.where(direction: :inbound).order(:created_at).last
    end

    # A clock time and a duration need no watch at all — the countdown IS the
    # alarm. What makes it one rather than a timer is the flag.
    describe "on the clock" do
      it "sets a flagged countdown, stoppable like any timer, that goes off saying what it was for", :aggregate_failures do
        expect { run({ label: "Wake up", seconds: 1200 }) }.not_to change(BuddyWatch, :count)

        timer = user.timers.order(:id).last
        expect(timer.name).to eq("Wake up")
        expect(timer.duration_ms).to eq(1_200_000)
        expect(Buddy::Alarms.alarm?(timer)).to be(true)
        expect(Buddy::Timers.buddy_timer?(user, timer)).to be(true)
        expect(Buddy::Timers.live_for(user)).to include(timer)

        Buddy::Timers.on_fired(timer)

        expect(last_said.body).to include("Wake up")
        expect(last_said.metadata["source"]).to eq("alarm")
      end

      # The message that asked came in a minute ago; a duration measured from
      # `now` would ring a minute early.
      it "measures a wall-clock moment to the moment, not from when the turn finished" do
        at = 90.minutes.from_now
        convo.byte_messages.where(direction: :outbound).delete_all
        convo.byte_messages.create!(
          user: user, direction: :outbound, state: :delivered,
          body: "alarm at 9", created_at: 1.minute.ago
        )

        run({ label: "Nine", at: at.iso8601 })

        expect(user.timers.order(:id).last.end_at).to be_within(2.seconds).of(at)
      end

      it "refuses a past time, one past a countdown's reach, a time AND a condition, or neither" do
        [
          { label: "Too late", at: 5.minutes.ago.iso8601 },
          { label: "Next week", at: 3.days.from_now.iso8601 },
          washer(seconds: 60),
          { label: "When?" },
        ].each { |payload|
          expect { run(payload) }.not_to(change { [user.timers.count, BuddyWatch.count] }, payload.inspect)
        }
      end
    end

    describe "setting one" do
      it "makes a one-shot alarm watch carrying what it's for, with the listener on the chip" do
        expect { run(washer) }.to change(BuddyWatch, :count).by(1)

        watch = BuddyWatch.last
        expect(watch.kind).to eq("alarm")
        expect(watch).to be_alarm
        expect(watch.body).to eq("Washer's done")
        expect(watch.trigger_scope).to eq("hass-trigger")
        expect(watch.one_shot).to be(true)

        chip = convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
        expect(chip.body).to include("hass-trigger:device_name::Washer type::stop")
        expect(Buddy::Context.send(:active_watches, convo).first[:does]).to eq("sounds an alarm")
      end

      it "stays armed when they want it every time, and stops on its own when bounded" do
        run(washer(repeat: true, expires: "today"))

        expect(BuddyWatch.last.one_shot).to be(false)
        expect(BuddyWatch.last.metadata["human_when"]).to eq("every time the washer stops")
        expect(BuddyWatch.last.expires_at).to be_present
      end

      it "refuses a listener that could never fire, or none at all, rather than saving a silent alarm" do
        expect {
          run(washer(listener: "definitelynotascope:action:stop", when_phrase: "when the thing stops"))
          run(washer(listener: nil))
        }.not_to change(BuddyWatch, :count)
      end
    end

    describe "when the condition happens" do
      let!(:watch) {
        run(washer)
        BuddyWatch.last
      }

      it "starts a countdown named and flagged as the alarm, and says nothing yet", :aggregate_failures do
        expect { Buddy::WatchMatcher.fire!(watch, washer_stopped) }.to change { user.timers.count }.by(1)

        timer = user.timers.order(:id).last
        expect(convo.byte_messages.where("metadata->>'source' = 'watch'")).to be_empty
        expect(timer.name).to eq("Washer's done")
        expect(Buddy::Alarms.alarm?(timer)).to be(true)
      end

      it "fires off the real trigger bus, and not on the washer starting or a different appliance" do
        expect {
          Buddy::WatchMatcher.dispatch(user, "hass-trigger", washer_stopped.merge("type" => "start"))
          Buddy::WatchMatcher.dispatch(user, "hass-trigger", washer_stopped.merge("device_name" => "Dryer"))
        }.not_to(change { user.timers.count })

        expect {
          Buddy::WatchMatcher.dispatch(user, "hass-trigger", washer_stopped)
        }.to change { user.timers.count }.by(1)
      end
    end

    describe "when it goes off" do
      it "says the thing it was set for, and pushes" do
        run(washer)
        Buddy::WatchMatcher.fire!(BuddyWatch.last, washer_stopped)

        Buddy::Timers.on_fired(user.timers.order(:id).last)

        expect(last_said.body).to include("Washer's done")
        expect(last_said.metadata["source"]).to eq("alarm")
        expect(WebPushNotifications).to have_received(:send_to_byte)
      end

      it "leaves an ordinary timer as a timer" do
        plain = Buddy::Timers.create!(user: user, seconds: 60, label: "Pasta")

        Buddy::Timers.on_fired(plain)

        expect(last_said.body).to include("Pasta")
        expect(last_said.metadata["source"]).to eq("timer")
      end
    end

    # remind_when and alarm resolve conditions through the same code so an
    # arrival watch and an arrival alarm can't disagree.
    it "resolves a condition the same way remind_when does" do
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

  # Typing "alarm" rings one. No model turn, no tool call, no waiting.
  describe "the fast path" do
    let(:user) { User.me }
    let!(:convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
    }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      allow(::WebPushNotifications).to receive(:update_count)
      allow(BuddyDeliverWorker).to receive(:perform_async)
      convo.update_columns(buddy_theme: "byte")
    end

    def say!(body)
      ByteMessageIntake.call(user: user, conversation: convo, body: body)
    end

    def alarms
      Timer.where(user_id: user.id).select { |t| Buddy::Alarms.alarm?(t) }
    end

    def chips
      convo.byte_messages.where(direction: :inbound).select { |m| m.metadata["kind"] == "buddy_activity" }
    end

    # The chip is the only line this produces: it pushes, and the countdown is
    # flagged `quick` so landing doesn't announce it a second time.
    it "rings a quick alarm on the bare word without the model, keeping their bubble and saying it once", :aggregate_failures do
      message = say!("alarm")

      expect(message.body).to eq("alarm")
      expect(message.direction).to eq("outbound")
      expect(alarms.length).to eq(1)
      expect(Buddy::Alarms.quick?(alarms.first)).to be(true)
      expect(BuddyDeliverWorker).not_to have_received(:perform_async)
      expect(WebPushNotifications).to have_received(:send_to_byte)
      expect(chips.last.metadata).to include("tool_name" => "alarm", "source" => "fast_path")

      Buddy::Timers.on_fired(alarms.first.tap { |t| t.update!(fired_at: Time.current) })

      expect(chips.length).to eq(1)
      expect(convo.byte_messages.where(direction: :inbound).map(&:body)).to eq([chips.first.body])
    end

    it "takes the punctuation people actually type, and leaves anything longer to the model" do
      ["alarm", "ALARM", "Alarm!", "alarm.", " alarm ", "alarm!!"].each do |text|
        expect(Buddy::Alarms.bare_request?(text)).to be(true), "expected #{text.inspect} to ring"
      end
      [
        "alarm in 20 minutes",
        "alarm at 7",
        "set an alarm for 6:30",
        "alarm when the washer finishes",
        "cancel the alarm",
        "what alarms do I have",
        "alarm?",
      ].each do |text|
        expect(Buddy::Alarms.bare_request?(text)).to be(false), "expected #{text.inspect} to go to the model"
      end
    end

    it "actually hands a longer one on rather than ringing" do
      say!("alarm in 20 minutes")

      expect(alarms).to be_empty
      expect(BuddyDeliverWorker).to have_received(:perform_async)
    end

    # Setting one off from the Mac CLI, a cron, or a Jil bash step: `hidden`
    # keeps the asking words out of the thread while what Buddy says stays.
    describe "triggering one without a visible message" do
      def say_hidden!(body)
        ByteMessageIntake.call(user: user, conversation: convo, body: body, metadata: { hidden: true })
      end

      it "still rings, hides their message, and leaves the chip visible" do
        expect(say_hidden!("alarm").metadata["hidden"]).to be(true)
        expect(alarms.length).to eq(1)
        expect(chips.last.metadata["hidden"]).to be_nil
      end

      # `fake!` because the suite runs Sidekiq inline and a five-minute
      # countdown would have TimerFireWorker reschedule itself forever.
      it "works the same for a timer" do
        Sidekiq::Testing.fake! { say_hidden!("5m pasta") }

        expect(Timer.where(user_id: user.id).count).to eq(1)
        expect(convo.byte_messages.where(direction: :outbound).last.metadata["hidden"]).to be(true)
      end
    end

    it "only fires on a Buddy thread" do
      shell = user.byte_conversations.create!(mode: :bash, name: "Terminal")

      ByteMessageIntake.call(user: user, conversation: shell, body: "alarm")

      expect(alarms).to be_empty
    end

    # The bubble is already posted, and losing what they typed is worse than a
    # missing alarm.
    it "still returns their message when ringing blows up" do
      allow(Buddy::Timers).to receive(:create!).and_raise("boom")
      allow(Buddy::Errors).to receive(:report)

      expect(say!("alarm")&.body).to eq("alarm")
      expect(Buddy::Errors).to have_received(:report)
    end
  end
end
