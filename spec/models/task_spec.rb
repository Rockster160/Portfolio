require "rails_helper"

RSpec.describe Task, type: :model do
  # A cron that CronParse can't read resolves to next_trigger_at: nil, which is
  # indistinguishable from a task that has no schedule at all — it just never runs
  # again, silently. These are what stands in front of that.
  describe "cron validation" do
    let(:user) { create(:user) }

    def build_task(cron)
      user.tasks.build(name: "Subject", listener: "tell:sub", code: "// noop", cron: cron)
    end

    it "accepts every cron form currently live in production" do
      [
        "1 * * * *",
        "0 7 * * *",
        "0 9 1 */2 *",
        "0 6 * * 1,3,5",
        "0 0 1 2,4,6,8,10,12 *",
        "0 7 * * 4 | 0 7 * * 0",
      ].each do |cron|
        expect(build_task(cron)).to be_valid, "expected #{cron.inspect} to be accepted"
      end
    end

    it "accepts a blank cron" do
      expect(build_task(nil)).to be_valid
      expect(build_task("")).to be_valid
    end

    it "rejects a cron it cannot read" do
      task = build_task("not a cron")

      expect(task).not_to be_valid
      expect(task.errors[:cron]).to be_present
    end

    describe "against the user's own anchors" do
      before do
        user.anchors.create!(key: "sun:sunset")
        user.anchors.create!(key: "trash:pickup")
      end

      it "accepts an anchor the user has, with or without an offset" do
        ["sun:sunset", "sun:sunset-5m", "trash:pickup+1h30m", "sun:sunset-5m | 0 6 * * *"].each do |cron|
          expect(build_task(cron)).to be_valid, "expected #{cron.inspect} to be accepted"
        end
      end

      # The point of the redesign: a user-created anchor validates without anyone
      # adding it to a list in Ruby.
      it "accepts an anchor created moments ago" do
        user.anchors.create!(key: "school:bell")

        expect(build_task("school:bell-10m")).to be_valid
      end

      # An anchor that doesn't exist yet does NOT block the save. A task written
      # before its feeder is a legitimate half-finished state, so it warns,
      # naming the missing anchor and the ones that do exist.
      it "saves against an anchor that doesn't exist yet, with a warning" do
        task = build_task("sun:sunet-5m")

        expect(task.save).to be(true)
        expect(task.cron_warnings.join).to include("sun:sunet", "sun:sunset", "trash:pickup")
        expect(build_task("sun:sunset-5m").cron_warnings).to be_empty
      end

      it "warns once per missing anchor in a multi-anchor cron" do
        task = build_task("sun:sunset-5m | school:bell-1h | tide:high+2h")

        expect(task).to be_valid
        expect(task.cron_warnings.length).to eq(2)
        expect(task.cron_warnings.join).to include("school:bell", "tide:high")
      end

      it "warns rather than blocking when another user owns the anchor" do
        create(:user).anchors.create!(key: "tide:high")
        task = build_task("tide:high-1h")

        expect(task).to be_valid
        expect(task.cron_warnings.join).to include("tide:high")
      end

      it "explains a malformed offset rather than calling the anchor unknown" do
        task = build_task("sun:sunset-5")

        expect(task).not_to be_valid
        expect(task.errors[:cron].join).to include("sun:sunset-5m")
      end

      # Unreadable is different from unsatisfied: no amount of setting things up
      # later makes "nonsense" a schedule, so that still blocks.
      it "still rejects a mix where one side is unreadable" do
        expect(build_task("sun:sunset-5m | nonsense")).not_to be_valid
        expect(build_task("sun:sunset-5m | sun:sunset-5")).not_to be_valid
      end
    end

    it "warns rather than blocking when the user has no anchors at all" do
      task = build_task("sun:sunset-5m")

      expect(task).to be_valid
      expect(task.cron_warnings.join).to include("sun:sunset")
    end

    it "has nothing to warn about for a plain cron" do
      expect(build_task("0 6 * * *").cron_warnings).to be_empty
      expect(build_task(nil).cron_warnings).to be_empty
    end

    # JilRunnerWorker finds tasks by `pending` and Jil::Executor stamps
    # last_trigger_at afterwards. If that stamp could be blocked by an unreadable
    # cron on a legacy row, the task would stay pending and re-run forever.
    it "lets a legacy row with an unreadable cron stamp last_trigger_at, until the cron is edited" do
      task = build_task("0 6 * * *")
      task.save!
      task.update_columns(cron: "garbage that predates this validation")

      expect(task.update(last_trigger_at: Time.current)).to be(true)
      expect(task.update(cron: "still garbage")).to be(false)
    end
  end

  describe "function args" do
    let(:user) { User.me }

    def build_task(listener)
      Task.new(user: user, name: "T", listener: listener, code: "")
    end

    describe "#function?" do
      it "is true for function listener" do
        expect(build_task("function()").function?).to eq(true)
        expect(build_task("function(name:String)").function?).to eq(true)
        expect(build_task("function(content([a:String]))::Hash").function?).to eq(true)
      end

      it "is false for non-function listeners" do
        expect(build_task("email:from:hunter").function?).to eq(false)
        expect(build_task("monitor:laundry").function?).to eq(false)
        expect(build_task(nil).function?).to eq(false)
        expect(build_task("").function?).to eq(false)
      end
    end

    describe "#function_args_str" do
      it "returns the raw args string, verbatim, and nil when there are none", :aggregate_failures do
        {
          "email:from:hunter"                                           => nil,
          nil                                                           => nil,
          "function()"                                                  => nil,
          "function()::Hash"                                            => nil,
          "function(name:String age:Numeric)"                           => "name:String age:Numeric",
          "function(content([person:String deposit:Numeric note:Text]))" =>
            "content([person:String deposit:Numeric note:Text])",
          'function("Start Event ID" TAB Numeric BR "New Filament" TAB String)::Hash' =>
            '"Start Event ID" TAB Numeric BR "New Filament" TAB String',
        }.each do |listener, want|
          expect(build_task(listener).function_args_str).to eq(want), listener.inspect
        end
      end
    end
  end

  describe "last execution" do
    let(:user) { FactoryBot.create(:user, phone: "5559990401") }
    let(:task) {
      described_class.create!(
        user: user, name: "Last Exec", listener: "tell:lastexec", code: "// noop", enabled: true,
      )
    }

    def make_execution(started_at:, finished_at:)
      Execution.create!(
        user: user, task: task, status: :success, auth_type: :trigger,
        started_at: started_at, finished_at: finished_at
      )
    end

    describe "#last_execution" do
      it "returns the most recently started finished execution" do
        make_execution(started_at: 3.minutes.ago, finished_at: 3.minutes.ago + 1.second)
        newest = make_execution(started_at: 1.minute.ago, finished_at: 1.minute.ago + 1.second)

        expect(task.last_execution).to eq(newest)
      end

      it "ignores executions that never finished" do
        finished = make_execution(started_at: 5.minutes.ago, finished_at: 4.minutes.ago)
        Execution.create!(
          user: user, task: task, status: :started, auth_type: :trigger, started_at: 1.minute.ago,
        )

        expect(task.last_execution).to eq(finished)
      end

      it "returns nil when the task has never run" do
        expect(task.last_execution).to be_nil
      end

      # Only (task_id, started_at DESC) is indexed, so ordering on finished_at
      # sorts every execution the task ever logged to return one row.
      it "orders on the indexed column, not finished_at" do
        make_execution(started_at: 2.minutes.ago, finished_at: 1.minute.ago)
        order_clause = task.executions.finished.order(:started_at).reverse_order.limit(1).to_sql[/ORDER BY.*/]

        expect(order_clause).to include("started_at")
        expect(order_clause).not_to include("finished_at")
      end
    end

    describe "#execute" do
      it "adopts the execution it just created, the newest after running twice" do
        first = task.execute({}, auth: :run, auth_id: user.id)
        expect(task.last_execution).to be(first.execution)

        second = task.execute({}, auth: :run, auth_id: user.id)
        expect(task.last_execution.id).to eq(second.execution.id)
      end

      it "reads stop_propagation off the run without another query" do
        executor = task.execute({}, auth: :run, auth_id: user.id)
        allow(task.executions).to receive(:finished).and_raise("should not re-query")

        expect { task.stop_propagation? }.not_to raise_error
        expect(executor.execution).to be_present
      end
    end
  end

  # What the editor is allowed to offer this person. `keep:` is what stops a
  # read-only shared task from being unrenderable for the person it's shared
  # with — see the note on Jil::Schema.
  describe ".schema" do
    let(:other) { create(:user) }

    it "gates the owner-only classes per user" do
      expect(described_class.schema(User.me)).to include("[Tesla]")
      expect(described_class.schema(other)).not_to include("[Tesla]")
    end

    it "still builds [Custom] from that person's own functions" do
      described_class.create!(
        user: other, name: "Do Thing", listener: "function(a:String)", code: "// noop", enabled: true,
      )

      expect(described_class.schema(other)).to include("#DoThing(a:String)")
    end

    it "passes kept classes through the gate" do
      expect(described_class.schema(other, keep: %w[Mac])).to include("[Mac]")
    end
  end

  describe "#used_classes" do
    def build_task(code)
      described_class.new(user: User.me, name: "T", listener: "", code: code)
    end

    it "names the classes a task calls" do
      task = build_task(<<~'JIL')
        active = Trip.active?()::Boolean
        nav = Tesla.navigate(stop)::Boolean
      JIL

      expect(task.used_classes).to contain_exactly("Trip", "Tesla")
    end

    it "skips instance calls on variables" do
      expect(build_task("len = stop.length()::Numeric").used_classes).to be_empty
    end

    it "reaches indented calls inside content blocks" do
      task = build_task(<<~'JIL')
        outer = Global.if({
          inner = Tesla.stop()::Boolean
        })::Any
      JIL

      expect(task.used_classes).to contain_exactly("Global", "Tesla")
    end

    it "is empty for a task with no code yet" do
      expect(build_task(nil).used_classes).to eq([])
    end
  end
end
