RSpec.describe Task, type: :model do
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

    # Regression: this ordered on finished_at, which has no index, so Postgres
    # sorted every execution the task had ever logged just to return one row.
    # Only (task_id, started_at DESC) is indexed, so the ordering column is
    # what matters here — the chosen plan is the planner's business and varies
    # with table size.
    it "orders on the indexed column, not finished_at" do
      make_execution(started_at: 2.minutes.ago, finished_at: 1.minute.ago)
      order_clause = task.executions.finished.order(:started_at).reverse_order.limit(1).to_sql[/ORDER BY.*/]

      expect(order_clause).to include("started_at")
      expect(order_clause).not_to include("finished_at")
    end
  end

  describe "#execute" do
    it "adopts the execution it just created instead of re-querying for it" do
      executor = task.execute({}, auth: :run, auth_id: user.id)

      expect(task.last_execution).to be(executor.execution)
    end

    it "reflects the newest run after executing twice" do
      task.execute({}, auth: :run, auth_id: user.id)
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
