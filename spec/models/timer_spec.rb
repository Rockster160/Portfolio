# == Schema Information
#
# Table name: timers
#
#  id                  :bigint           not null, primary key
#  user_id             :bigint           not null
#  timer_page_id       :bigint
#  name                :text             default(""), not null
#  kind                :integer          default("countdown"), not null
#  color               :text
#  section_id          :integer
#  pos_x               :integer          default(0), not null
#  pos_y               :integer          default(0), not null
#  width               :integer          default(0), not null
#  height              :integer          default(0), not null
#  duration_ms         :bigint
#  started_at          :datetime
#  paused_at           :datetime
#  paused_remaining_ms :bigint
#  end_at              :datetime
#  repeat              :boolean          default(FALSE), not null
#  repeat_count        :integer          default(0), not null
#  require_confirm_tap :boolean          default(FALSE), not null
#  value               :integer          default(0), not null
#  step                :integer          default(1), not null
#  min_value           :integer
#  max_value           :integer
#  reset_value         :integer          default(0), not null
#  dial_config         :jsonb            not null
#  dial_step_index     :integer          default(0), not null
#  callbacks           :jsonb            not null
#  fire_jid            :string
#  fire_scheduled_for  :datetime
#  fired_at            :datetime
#  confirmed_at        :datetime
#  archived_at         :datetime
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  disabled            :boolean          default(FALSE), not null
#
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

    it "resets a counter to reset_value and a dial to step 0" do
      counter = create(:timer, user: user, kind: :counter, duration_ms: nil, value: 7, reset_value: 0)
      dial = create(:timer, user: user, kind: :dial, duration_ms: nil, dial_step_index: 3,
                            dial_config: { sections: [{ name: "a" }, { name: "b" }] })
      counter.reset!
      dial.reset!
      expect(counter.value).to eq(0)
      expect(dial.dial_step_index).to eq(0)
    end
  end

  describe "#advance_dial!" do
    it "counts all subs as separate steps and wraps only at the true total" do
      sections = 8.times.map { |i| { name: "S#{i}", subs: %w[a b c] } }
      timer = create(:timer, user: user, kind: :dial, duration_ms: nil, dial_config: { sections: sections })
      12.times { timer.advance_dial!(by: 1) }
      expect(timer.dial_step_index).to eq(12)
      12.times { timer.advance_dial!(by: 1) }
      expect(timer.dial_step_index).to eq(0)
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

    # `by` is scaled through the counter's step, `amount` is a raw delta, and
    # max_value is display-only.
    it "applies `by` through the step and `amount` raw, unbounded", :aggregate_failures do
      [
        [{ step: 1, value: 0 }, { by: 1 }, 1],
        [{ step: 1, value: 0 }, { by: -1 }, -1],
        [{ step: 3, value: 0 }, { by: 1 }, 3],
        [{ step: 3, value: 43 }, { amount: 18 }, 61],
        [{ step: 1, value: 10 }, { amount: -4 }, 6],
        [{ step: 1, value: 2, max_value: 2 }, { by: 1 }, 3],
      ].each do |attrs, args, want|
        timer.update!(attrs)
        timer.apply_increment!(**args)
        expect(timer.value).to eq(want), "#{attrs} #{args}"
      end
    end

    it "reports the direction of an `amount` to counter_reaches clauses" do
      target = create(:timer, user: user, kind: :counter, duration_ms: nil, value: 0)
      timer.update!(value: 10, callbacks: [
        { id: "down", when: { type: "counter_reaches", value: 4, direction: "decreasing" },
                      then: { type: "chain", target_timer_id: target.id, op: "increment", by: 1 } },
      ])
      allow(MonitorChannel).to receive(:broadcast_to)

      timer.apply_increment!(amount: -6)
      expect(target.reload.value).to eq(1)
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
    it "dispatches only the callbacks whose `when` matches, legacy shape included" do
      timer = create(:timer,
        user:      user,
        callbacks: [
          { id: "a", when: { type: "complete" }, then: { type: "push" } },
          { id: "b", when: { type: "confirm"  }, then: { type: "push" } },
          { id: "leg", event: "complete", type: "push" },
        ],
      )
      expect(WebPushNotifications).to receive(:send_to).twice
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

    it "chains :increment to a counter or a dial target, broadcasting the target" do
      counter = create(:timer, user: user, kind: :counter, duration_ms: nil, value: 0)
      dial = create(:timer,
        user:        user,
        kind:        :dial,
        duration_ms: nil,
        dial_config: { sections: [{ name: "a" }, { name: "b" }, { name: "c" }] })
      allow(MonitorChannel).to receive(:broadcast_to)

      timer.dispatch_then(type: :chain, target_timer_id: counter.id, op: :increment, by: 3)
      timer.dispatch_then(type: :chain, target_timer_id: dial.id, op: :increment, by: 1)

      expect(counter.reload.value).to eq(3)
      expect(dial.reload.dial_step_index).to eq(1)
      expect(MonitorChannel).to have_received(:broadcast_to).with(
        user, hash_including(data: hash_including(reason: :chained, timer_id: counter.id)),
      )
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
    it "fires callbacks for a repeating timer but does NOT auto-restart server-side" do
      # The client drives the restart of repeating timers on its own
      # fire-detection, so the model only fires :complete callbacks and
      # broadcasts :fired, the same as a non-repeat.
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

    it "clears the fire job when it runs, and confirm! returns to a neutral starting state" do
      timer = create(:timer, user: user, duration_ms: 60_000)
      allow(MonitorChannel).to receive(:broadcast_to)
      Sidekiq::Testing.fake! do
        timer.start!
        expect(timer.fire_jid).to be_present
        timer.fire_and_maybe_repeat!
        timer.reload
        expect(timer.fired_at).to be_present
        expect(timer.fire_jid).to be_nil
        expect(timer.fire_scheduled_for).to be_nil
        timer.confirm!
      end
      timer.reload
      expect(timer.confirmed_at).to be_present
      expect(timer.started_at).to be_nil
      expect(timer.end_at).to be_nil
      expect(timer.paused_at).to be_nil
      expect(timer.fired_at).to be_nil
    end
  end
end
