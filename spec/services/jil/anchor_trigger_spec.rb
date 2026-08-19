require "rails_helper"

# An anchored trigger is only worth anything if it actually RUNS. These go all
# the way through: schedule it from Jil, let JilRunnerWorker pick it up the way
# it does in production, and assert the listening task executed.
RSpec.describe "Jil: anchored triggers", type: :service do
  let(:user) { create(:user) }
  let(:tz) { ActiveSupport::TimeZone[user.timezone] }
  let(:tonight) { tz.local(2026, 8, 19, 20, 24) }

  let!(:anchor) {
    user.anchors.create!(key: "sun:sunset").tap { |a|
      a.set_occurrence(tonight, identifier: "2026-08-19")
      a.set_occurrence(tonight + 1.day - 1.minute, identifier: "2026-08-20")
    }
  }

  # The task that's listening for the scope the trigger fires.
  let!(:listener) {
    user.tasks.create!(
      name: "Porch Lights", listener: "porch_lights", enabled: true,
      code: <<~'JIL'
        d = Global.input_data()::Hash
        room = d.get("room")::String
        out = Global.print("lights on #{room}")::String
      JIL
    )
  }

  def schedule(expression="sun:sunset-5m", name="porch-lights")
    result = Jil::Executor.call(user, <<~JIL)
      s = Anchor.trigger("#{expression}", "#{name}", "porch_lights", {})::Schedule
      out = Global.return(s)::Hash
    JIL
    expect(result.ctx[:error]).to be_nil, "Jil error: #{result.ctx[:error].inspect}"
    result
  end

  before { allow(Jil::Schedule).to receive(:add_job) } # no real sidekiq

  describe "scheduling" do
    it "creates a trigger bound to the occurrence it resolved" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) { schedule }

      trigger = user.scheduled_triggers.reload.sole
      expect(trigger.trigger).to eq("porch_lights")
      expect(trigger.execute_at).to be_within(1.second).of(tonight - 5.minutes)
      expect(trigger.anchor_occurrence.identifier).to eq("2026-08-19")
      expect(trigger.offset_seconds).to eq(-300)
    end

    it "updates rather than stacking when scheduled again" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) { 3.times { schedule } }

      expect(user.scheduled_triggers.reload.count).to eq(1)
    end

    it "keeps separate names apart on the same occurrence" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) do
        schedule("sun:sunset-5m", "porch-lights")
        schedule("sun:sunset-1h", "close-blinds")
      end

      expect(user.scheduled_triggers.reload.count).to eq(2)
    end

    it "can pin one specific occurrence" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) { schedule("sun:sunset[2026-08-20]-5m") }

      expect(user.scheduled_triggers.sole.anchor_occurrence.identifier).to eq("2026-08-20")
    end

    # A trigger created in the past would fire the instant it exists, which
    # reads as "the reminder arrived at the event".
    it "refuses to schedule something already gone by" do
      travel_to(tz.local(2026, 8, 19, 23, 0)) { schedule("sun:sunset[2026-08-19]-5m") }

      expect(user.scheduled_triggers.count).to eq(0)
    end

    it "does nothing for an anchor that doesn't exist" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) { schedule("moon:rise-5m") }

      expect(user.scheduled_triggers.count).to eq(0)
    end
  end

  describe "when the anchor moves" do
    it "carries the pending trigger with it" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) { schedule }

      anchor.set_occurrence(tonight + 18.minutes, identifier: "2026-08-19")

      expect(user.scheduled_triggers.sole.execute_at).to(
        be_within(1.second).of(tonight + 13.minutes),
      )
    end
  end

  describe "untrigger" do
    it "removes the scheduled row" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) do
        schedule
        Jil::Executor.call(user, <<~JIL)
          gone = Anchor.untrigger("sun:sunset-5m", "porch-lights")::Boolean
          out = Global.return(gone)::Boolean
        JIL
      end

      expect(user.scheduled_triggers.count).to eq(0)
    end
  end

  # The part that actually matters: does it RUN.
  describe "execution" do
    def run_worker
      JilRunnerWorker.new.perform(user.id)
    end

    it "fires the listening task once its moment arrives" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) { schedule }

      travel_to(tonight - 5.minutes + 1.second) { run_worker }

      expect(listener.executions.count).to eq(1)
    end

    it "does not fire early" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) { schedule }

      travel_to(tonight - 20.minutes) { run_worker }

      expect(listener.executions.count).to eq(0)
      expect(user.scheduled_triggers.reload.sole).not_to be_started
    end

    it "completes the trigger rather than leaving it to re-fire" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) { schedule }

      travel_to(tonight - 5.minutes + 1.second) do
        run_worker
        run_worker
      end

      expect(listener.executions.count).to eq(1)
      expect(user.scheduled_triggers.reload.sole).to be_completed
    end

    it "hands the trigger's data to the task" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) do
        result = Jil::Executor.call(user, <<~JIL)
          d = Hash.new({
            k = Hash.keyval("room", "porch")::Keyval
          })::Hash
          s = Anchor.trigger("sun:sunset-5m", "porch-lights", "porch_lights", d)::Schedule
          out = Global.return(s)::Hash
        JIL
        expect(result.ctx[:error]).to be_nil
      end

      travel_to(tonight - 5.minutes + 1.second) { run_worker }

      expect(listener.executions.last.ctx["output"].to_s).to include("lights on porch")
    end

    # A move that lands the trigger later must not let the old time fire it.
    it "fires at the moved time, not the original" do
      travel_to(tz.local(2026, 8, 19, 12, 0)) { schedule }
      anchor.set_occurrence(tonight + 30.minutes, identifier: "2026-08-19")

      travel_to(tonight - 5.minutes + 1.second) { run_worker }
      expect(listener.executions.count).to eq(0)

      travel_to(tonight + 25.minutes + 1.second) { run_worker }
      expect(listener.executions.count).to eq(1)
    end
  end
end
