require "rails_helper"

RSpec.describe "Jil: Anchor", type: :service do
  # Anchors exist so a schedule can hang off a moving time WITHOUT anyone editing
  # Ruby. That only holds if a Jil task can create and feed one, which is what
  # these cover.
  describe "methods" do
    let(:user) { create(:user) }
    let(:tz) { ActiveSupport::TimeZone[user.timezone] }
    let(:tonight) { tz.local(2026, 8, 19, 20, 24) }

    # Every date in here is written out in full, so the wall clock has to be
    # pinned or the file only means what it says on one particular afternoon.
    # `next_trigger_at` answers with the next occurrence STILL AHEAD: the pickup
    # example below passed until the real clock reached the morning it names, and
    # from that moment it was going to fail on every run forever. Three examples
    # already pinned their own clock for this reason; now the file does it once.
    noon = ActiveSupport::TimeZone["America/Denver"].local(2026, 8, 19, 12, 0)

    around { |example| travel_to(noon) { example.run } }

    def run(code)
      Jil::Executor.call(user, code).tap { |result|
        expect(result.ctx[:error]).to be_nil, "Jil error: #{result.ctx[:error].inspect}"
      }
    end

    it "creates the anchor on first write" do
      run(<<~'JIL')
        at = Date.new(2026, 8, 19, 20, 24)::Date
        a = Anchor.set("sun:sunset", at, "2026-08-19")::Anchor
        out = Global.return(a)::Hash
      JIL

      anchor = Anchor.for(user, "sun:sunset")
      expect(anchor).to be_present
      expect(anchor.occurrences.sole.occurs_at).to be_within(1.second).of(tonight)
      expect(anchor.occurrences.sole.identifier).to eq("2026-08-19")
    end

    it "makes a brand new key usable in a cron immediately" do
      run(<<~'JIL')
        at = Date.new(2026, 8, 20, 7, 0)::Date
        a = Anchor.set("trash:pickup", at, "2026-08-20")::Anchor
        out = Global.return(a)::Hash
      JIL

      task = user.tasks.create!(
        name: "Bins", listener: "tell:bins", code: "// noop", enabled: true,
        cron: "trash:pickup-30m",
      )

      expect(task).to be_valid
      expect(task.next_trigger_at).to be_within(1.second).of(tz.local(2026, 8, 20, 6, 30))
    end

    it "replaces the occurrence when the same identifier is written again" do
      ["20, 24", "20, 34"].each do |clock|
        run(<<~JIL)
          at = Date.new(2026, 8, 19, #{clock})::Date
          a = Anchor.set("sun:sunset", at, "2026-08-19")::Anchor
          out = Global.return(a)::Hash
        JIL
      end

      anchor = Anchor.for(user, "sun:sunset")
      expect(anchor.occurrences.count).to eq(1)
      expect(anchor.occurrences.sole.occurs_at).to be_within(1.second).of(tonight + 10.minutes)
    end

    it "appends when no identifier is given" do
      [19, 20].each do |day|
        run(<<~JIL)
          at = Date.new(2026, 8, #{day}, 20, 24)::Date
          a = Anchor.set("sun:sunset", at)::Anchor
          out = Global.return(a)::Hash
        JIL
      end

      expect(Anchor.for(user, "sun:sunset").occurrences.count).to eq(2)
    end

    it "removes one occurrence and keeps the anchor" do
      anchor = user.anchors.create!(key: "sun:sunset")
      anchor.set_occurrence(tonight, identifier: "keep")
      anchor.set_occurrence(tonight + 1.day, identifier: "drop")

      run(<<~'JIL')
        gone = Anchor.remove("sun:sunset", "drop")::Boolean
        out = Global.return(gone)::Boolean
      JIL

      expect(anchor.occurrences.reload.pluck(:identifier)).to eq(["keep"])
      expect(Anchor.for(user, "sun:sunset")).to be_present
    end

    it "clears every occurrence but leaves the anchor valid for a cron" do
      anchor = user.anchors.create!(key: "sun:sunset")
      anchor.set_occurrence(tonight, identifier: "a")

      run(<<~'JIL')
        done = Anchor.clear("sun:sunset")::Boolean
        out = Global.return(done)::Boolean
      JIL

      expect(anchor.occurrences.reload).to be_empty
      expect(Anchor.for(user, "sun:sunset")).to be_present
    end

    it "answers what a cron of the same string would" do
      user.anchors.create!(key: "sun:sunset").set_occurrence(tonight, identifier: "a")

      result = run(<<~'JIL')
        at = Anchor.next("sun:sunset-5m")::Date
        out = Global.return(at)::Date
      JIL

      expect(Time.parse(result.ctx[:return_val].to_s)).to be_within(1.second).of(tonight - 5.minutes)
    end

    it "re-resolves a dependent task as a side effect of the write" do
      user.anchors.create!(key: "sun:sunset").set_occurrence(tonight, identifier: "2026-08-19")
      task = user.tasks.create!(
        name: "Porch", listener: "tell:porch", code: "// noop", enabled: true,
        cron: "sun:sunset-5m",
      )

      run(<<~'JIL')
        at = Date.new(2026, 8, 19, 20, 42)::Date
        a = Anchor.set("sun:sunset", at, "2026-08-19")::Anchor
        out = Global.return(a)::Hash
      JIL

      expect(task.reload.next_trigger_at).to be_within(1.second).of(tonight + 13.minutes)
    end

    it "won't create an anchor from a key that isn't domain:event" do
      run(<<~'JIL')
        at = Date.new(2026, 8, 19, 20, 24)::Date
        a = Anchor.set("sunset", at)::Anchor
        out = Global.return(a)::Hash
      JIL

      expect(user.anchors.reload).to be_empty
    end
  end

  # An anchored trigger is only worth anything if it actually RUNS. These go all
  # the way through: schedule it from Jil, let JilRunnerWorker pick it up the way
  # it does in production, and assert the listening task executed.
  describe "anchored triggers" do
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
end
