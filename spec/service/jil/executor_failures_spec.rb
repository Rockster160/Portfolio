require "rails_helper"

RSpec.describe Jil::Executor do
  let(:user) { create(:user) }

  def run(code, task: nil)
    described_class.call(user, code, {}, task: task)
  end

  describe "a monitor refresh from inside a task" do
    it "takes its content block and refreshes once the run ends", :aggregate_failures do
      calls = []
      allow(described_class).to(receive(:run_trigger).and_wrap_original { |orig, usr, trig, data, **kw|
        next (calls << data) && [] if trig.to_s == "monitor"

        orig.call(usr, trig, data, **kw)
      })

      exe = run(
        <<~JIL,
          a = Global.triggerNow("monitor", {
            b = Keyval.new("monitor", "upcoming")::Keyval
          })::Schedule
        JIL
      )

      expect(exe.execution.reload.status).to eq("success")
      expect(calls.map { |data| data.to_h.with_indifferent_access[:monitor] }).to eq(["upcoming"])
    end
  end

  describe "stopping from inside a block" do
    it "ends quietly even when the line holding it casts to something else", :aggregate_failures do
      exe = run(
        <<~JIL,
          a = Global.try({
            b = nothere.get("x")::Any
          }, {
            c = Global.exit()::Any
          })::Hash
          d = Global.print("after")::String
        JIL
      )

      expect(exe.execution.reload.status).to eq("success")
      expect(exe.ctx[:output]).to be_empty
    end
  end

  describe "a task that raises" do
    it "is a row on the errors page, grouped by its task", :aggregate_failures do
      task = create(:task, user: user, name: "Breaks")
      exe = run("a = nothere.get(\"x\")::Any", task: task)

      report = ErrorReport.sole
      expect(exe.execution.reload.status).to eq("failed")
      expect(report).to have_attributes(section: "jil:task:#{task.id}", tag: "task", user_id: user.id)
      expect(report.extra).to include("execution_id" => exe.execution.id, "line" => "a")
    end
  end
end
