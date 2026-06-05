require "rails_helper"

RSpec.describe Timer do
  let(:user) { create(:user) }

  describe "#start!" do
    it "sets started_at, end_at, and schedules a fire job" do
      timer = create(:timer, user: user, duration_ms: 60_000)

      Sidekiq::Testing.fake! do
        TimerFireWorker.clear
        freeze_time do
          timer.start!
          expect(timer.started_at).to eq(Time.current)
          expect(timer.end_at).to eq(Time.current + 60.seconds)
          expect(timer.fire_jid).to be_present
          expect(TimerFireWorker.jobs.size).to eq(1)
        end
      end
    end
  end

  describe "#pause! and #resume!" do
    it "freezes remaining_ms on pause and rehydrates end_at on resume" do
      timer = create(:timer, user: user, duration_ms: 60_000)

      Sidekiq::Testing.fake! do
        timer.start!
        travel(20.seconds) do
          timer.pause!
          expect(timer.paused_remaining_ms).to be_within(1000).of(40_000)
          expect(timer.started_at).to be_nil
          expect(timer.end_at).to be_nil
          expect(timer.fire_jid).to be_nil
        end

        travel(60.seconds) do
          timer.resume!
          expect(timer.end_at).to be_within(1.second).of(Time.current + 40.seconds)
          expect(timer.fire_jid).to be_present
        end
      end
    end
  end

  describe "#reset!" do
    it "clears countdown state and cancels the fire" do
      timer = create(:timer, user: user, duration_ms: 60_000)
      Sidekiq::Testing.fake! do
        timer.start!
        timer.reset!
        expect(timer.started_at).to be_nil
        expect(timer.fire_jid).to be_nil
      end
    end

    it "resets a counter to reset_value" do
      timer = create(:timer, user: user, kind: :counter, duration_ms: nil, value: 7, reset_value: 0)
      timer.reset!
      expect(timer.value).to eq(0)
    end

    it "resets a dial to step 0" do
      timer = create(:timer, user: user, kind: :dial, duration_ms: nil, dial_step_index: 3,
                             dial_config: { sections: [{ name: "a" }, { name: "b" }] })
      timer.reset!
      expect(timer.dial_step_index).to eq(0)
    end
  end

  describe "#advance_dial!" do
    it "counts all subs as separate steps and wraps only at the true total" do
      sections = 8.times.map { |i| { name: "S#{i}", subs: %w[a b c] } }
      timer = create(:timer, user: user, kind: :dial, duration_ms: nil, dial_config: { sections: sections })
      24.times { |i| timer.advance_dial!(by: 1) }
      expect(timer.dial_step_index).to eq(0) # wrap after exactly 24 advances
    end

    it "does not wrap early (regression: 8x3 dials hit 12 and wrapped)" do
      sections = 8.times.map { |i| { name: "S#{i}", subs: %w[a b c] } }
      timer = create(:timer, user: user, kind: :dial, duration_ms: nil, dial_config: { sections: sections })
      12.times { timer.advance_dial!(by: 1) }
      expect(timer.dial_step_index).to eq(12)
    end

    it "fires dial_step callbacks only when the when.section matches" do
      target = create(:timer, user: user, kind: :counter, duration_ms: nil, value: 0)
      timer  = create(:timer,
        user:        user,
        kind:        :dial,
        duration_ms: nil,
        dial_config: { sections: [{ name: "Prep" }, { name: "Swarm" }, { name: "Settle" }] },
        callbacks:   [
          { id: "x",
            when: { type: "dial_step", section: "Swarm" },
            then: { type: "chain", target_timer_id: target.id, op: "increment", by: 1 } },
        ])
      allow(MonitorChannel).to receive(:broadcast_to)
      timer.advance_dial!(by: 1) # → Swarm
      expect(target.reload.value).to eq(1)
      timer.advance_dial!(by: 1) # → Settle, no match → no fire
      expect(target.reload.value).to eq(1)
    end
  end

  describe "#goto_dial_section!" do
    it "moves the dial to the first step of the named section, case-insensitive" do
      timer = create(:timer,
        user:        user,
        kind:        :dial,
        duration_ms: nil,
        dial_config: { sections: [{ name: "Prep" }, { name: "Swarm", subs: %w[a b] }, { name: "Settle" }] })
      timer.goto_dial_section!("settle")
      expect(timer.reload.dial_step_index).to eq(3)
    end

    it "silently no-ops on an unknown section name" do
      timer = create(:timer,
        user:        user,
        kind:        :dial,
        duration_ms: nil,
        dial_config: { sections: [{ name: "Prep" }, { name: "Swarm" }] },
        dial_step_index: 1)
      expect { timer.goto_dial_section!("Nowhere") }.not_to change { timer.reload.dial_step_index }
    end
  end

  describe "#apply_increment!" do
    let(:timer) { create(:timer, user: user, kind: :counter, duration_ms: nil, value: 0, step: 1) }

    it "increments by step" do
      timer.apply_increment!(by: 1)
      expect(timer.value).to eq(1)
    end

    it "allows overflow when no bounds are set" do
      timer.apply_increment!(by: -1)
      expect(timer.value).to eq(-1)
    end

    it "lets the value go past max_value (display-only bound)" do
      timer.update!(max_value: 2)
      3.times { timer.apply_increment!(by: 1) }
      expect(timer.value).to eq(3)
    end

    it "fires complete callback once when the counter exactly hits max" do
      timer.update!(max_value: 2, callbacks: [
        { id: "x", when: { type: "complete" }, then: { type: "push" } },
      ])
      expect(WebPushNotifications).to receive(:send_to).once
      2.times { timer.apply_increment!(by: 1) }
    end

    it "counter_reaches fires only at the named value, optionally filtered by direction" do
      target_a = create(:timer, user: user, kind: :counter, duration_ms: nil, value: 0)
      target_b = create(:timer, user: user, kind: :counter, duration_ms: nil, value: 0)
      timer.update!(callbacks: [
        { id: "any",  when: { type: "counter_reaches", value: 2, direction: "any" },
                      then: { type: "chain", target_timer_id: target_a.id, op: "increment", by: 1 } },
        { id: "up",   when: { type: "counter_reaches", value: 2, direction: "increasing" },
                      then: { type: "chain", target_timer_id: target_b.id, op: "increment", by: 1 } },
      ])
      allow(MonitorChannel).to receive(:broadcast_to)

      # Increment up to 2 — both fire
      2.times { timer.apply_increment!(by: 1) }
      expect(target_a.reload.value).to eq(1)
      expect(target_b.reload.value).to eq(1)

      # Decrement back through 2 — only the `any` rule fires
      timer.apply_increment!(by: 1)        # value: 3
      timer.apply_increment!(by: -1)       # value: 2 (decreasing)
      expect(target_a.reload.value).to eq(2)
      expect(target_b.reload.value).to eq(1)
    end
  end

  describe "#fire_callbacks!" do
    it "only dispatches when the `when` clause matches the event" do
      timer = create(:timer,
        user:      user,
        callbacks: [
          { id: "a", when: { type: "complete" }, then: { type: "push" } },
          { id: "b", when: { type: "confirm"  }, then: { type: "push" } },
        ],
      )
      expect(WebPushNotifications).to receive(:send_to).once
      timer.fire_callbacks!(event: :complete)
    end

    it "interprets legacy {event, type, ...} callbacks via the adapter" do
      timer = create(:timer,
        user:      user,
        callbacks: [{ id: "leg", event: "complete", type: "push" }],
      )
      expect(WebPushNotifications).to receive(:send_to).once
      timer.fire_callbacks!(event: :complete)
    end
  end

  describe "#dispatch_then" do
    let(:timer) { create(:timer, user: user, name: "Tea") }

    it "fires push via WebPushNotifications" do
      expect(WebPushNotifications).to receive(:send_to).with(user, hash_including(title: "Tea"), channel: :timers)
      timer.dispatch_then(type: :push)
    end

    it "fires jil trigger" do
      allow(::Jil).to receive(:trigger)
      timer.dispatch_then(type: :jil, trigger: "test_scope")
      expect(::Jil).to have_received(:trigger).with(user, :test_scope, hash_including(timer_id: timer.id), auth: :trigger)
    end

    it "chains :increment to a counter target" do
      target = create(:timer, user: user, kind: :counter, duration_ms: nil, value: 0)
      allow(MonitorChannel).to receive(:broadcast_to)
      timer.dispatch_then(type: :chain, target_timer_id: target.id, op: :increment, by: 3)
      expect(target.reload.value).to eq(3)
    end

    it "chains :increment against a dial target advances the dial step" do
      target = create(:timer,
        user:        user,
        kind:        :dial,
        duration_ms: nil,
        dial_config: { sections: [{ name: "a" }, { name: "b" }, { name: "c" }] })
      allow(MonitorChannel).to receive(:broadcast_to)
      timer.dispatch_then(type: :chain, target_timer_id: target.id, op: :increment, by: 1)
      expect(target.reload.dial_step_index).to eq(1)
    end

    it "chain broadcasts the target so the page sees the change" do
      target = create(:timer, user: user, kind: :counter, duration_ms: nil, value: 0)
      expect(MonitorChannel).to receive(:broadcast_to).with(
        user, hash_including(data: hash_including(reason: :chained, timer_id: target.id)),
      )
      timer.dispatch_then(type: :chain, target_timer_id: target.id, op: :increment, by: 1)
    end

    it "chain :goto parks a dial target at the named section" do
      target = create(:timer,
        user:        user,
        kind:        :dial,
        duration_ms: nil,
        dial_config: { sections: [{ name: "Prep" }, { name: "Swarm" }, { name: "Settle" }] })
      allow(MonitorChannel).to receive(:broadcast_to)
      timer.dispatch_then(type: :chain, target_timer_id: target.id, op: :goto, section: "Settle")
      expect(target.reload.dial_step_index).to eq(2)
    end
  end

  describe "countdown_at scheduling" do
    it "schedules a TimerCallbackWorker per non-sound countdown_at callback at start" do
      timer = create(:timer,
        user:        user,
        duration_ms: 60_000,
        callbacks:   [
          { id: "push-30",  when: { type: "countdown_at", remaining_ms: 30_000 },
                            then: { type: "push" } },
          { id: "sound-10", when: { type: "countdown_at", remaining_ms: 10_000 },
                            then: { type: "sound", chime: "soft", cadence: "once" } },
        ])
      Sidekiq::Testing.fake! do
        TimerCallbackWorker.clear
        timer.start!
        expect(TimerCallbackWorker.jobs.size).to eq(1)
        expect(TimerCallbackWorker.jobs.first["args"]).to eq([timer.id, "push-30"])
      end
    end

    it "fire_callback_by_id! dispatches the then-clause for that single callback" do
      target = create(:timer, user: user, kind: :counter, duration_ms: nil, value: 0)
      timer = create(:timer,
        user:        user,
        duration_ms: 60_000,
        callbacks:   [
          { id: "bump", when: { type: "countdown_at", remaining_ms: 30_000 },
                        then: { type: "chain", target_timer_id: target.id, op: "increment", by: 5 } },
        ])
      allow(MonitorChannel).to receive(:broadcast_to)
      timer.fire_callback_by_id!("bump")
      expect(target.reload.value).to eq(5)
    end
  end

  describe "#fire_and_maybe_repeat!" do
    it "sets fired_at and broadcasts when not repeating" do
      timer = create(:timer, user: user, repeat: false)
      allow(MonitorChannel).to receive(:broadcast_to)
      timer.fire_and_maybe_repeat!
      expect(timer.reload.fired_at).to be_present
    end

    it "fires callbacks for a repeating timer but does NOT auto-restart server-side" do
      # The client now drives the restart of repeating timers on its
      # fire-detection. The model just fires :complete callbacks and
      # broadcasts :fired same as a non-repeat — this removes the race
      # between worker-restart and client-restart and lets repeats work
      # even when Sidekiq isn't actively restarting things.
      push_called = false
      allow(WebPushNotifications).to receive(:send_to) { push_called = true }
      allow(MonitorChannel).to receive(:broadcast_to)

      timer = create(:timer,
        user:        user,
        repeat:      true,
        duration_ms: 60_000,
        callbacks:   [{ id: "p", when: { type: "complete" }, then: { type: "push" } }])
      Sidekiq::Testing.fake! do
        timer.fire_and_maybe_repeat!
      end

      expect(push_called).to be(true)
      expect(timer.reload.fired_at).to be_present
      expect(timer.reload.started_at).to be_nil
    end

    it "confirm! returns the timer to a neutral starting state" do
      timer = create(:timer, user: user, duration_ms: 60_000)
      Sidekiq::Testing.fake! do
        timer.start!
        timer.fire_and_maybe_repeat!
        expect(timer.reload.fired_at).to be_present
        timer.confirm!
      end
      timer.reload
      expect(timer.confirmed_at).to be_present
      expect(timer.started_at).to be_nil
      expect(timer.end_at).to be_nil
      expect(timer.paused_at).to be_nil
      expect(timer.fired_at).to be_nil
    end

    it "clears fire_jid and fire_scheduled_for after the job runs" do
      timer = create(:timer, user: user, duration_ms: 60_000)
      allow(MonitorChannel).to receive(:broadcast_to)
      Sidekiq::Testing.fake! do
        timer.start!
        expect(timer.fire_jid).to be_present
        timer.fire_and_maybe_repeat!
        expect(timer.reload.fire_jid).to be_nil
        expect(timer.reload.fire_scheduled_for).to be_nil
      end
    end
  end
end
