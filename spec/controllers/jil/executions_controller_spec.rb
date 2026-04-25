require "rails_helper"

RSpec.describe Jil::ExecutionsController, type: :controller do
  let(:user) { FactoryBot.create(:user, phone: "5550000001") }
  let(:other_user) { FactoryBot.create(:user, phone: "5550000002") }
  let!(:task_a) { Task.create!(user: user, name: "Looper", listener: "tell:foo", code: "// noop", enabled: true) }
  let!(:task_b) { Task.create!(user: user, name: "Steady", listener: "tell:bar", code: "// noop", enabled: true) }

  before { sign_in user }

  describe "GET #dashboard" do
    render_views
    let(:now) { Time.current }

    before do
      # task_a: 5 rapid-fire executions (1s apart)
      5.times do |i|
        Execution.create!(
          user: user, task: task_a, status: :success, auth_type: :trigger,
          started_at: now - (5 - i).seconds,
          finished_at: now - (5 - i).seconds + 0.1
        )
      end
      # task_b: 2 well-spaced executions (5 minutes apart)
      Execution.create!(
        user: user, task: task_b, status: :success, auth_type: :trigger,
        started_at: now - 10.minutes, finished_at: now - 10.minutes + 0.5
      )
      Execution.create!(
        user: user, task: task_b, status: :failed, auth_type: :trigger,
        started_at: now - 5.minutes, finished_at: now - 5.minutes + 0.5,
        payload: ExecutionPayload.create!(ctx: { error: "boom" })
      )
      # other_user: should be excluded
      Execution.create!(
        user: other_user, task: nil, status: :success, auth_type: :trigger,
        started_at: now - 1.minute, finished_at: now
      )
    end

    it "returns a successful response" do
      get :dashboard
      expect(response).to be_successful
    end

    it "renders the view without errors" do
      get :dashboard
      expect(response.body).to include("Execution Dashboard")
      expect(response.body).to include("Top offenders")
      expect(response.body).to include("Rapid-fire detector")
      expect(response.body).to include("histogram-data")
    end

    it "scopes data to the current user only" do
      get :dashboard
      expect(controller.instance_variable_get(:@total_count)).to eq(7)
    end

    it "ranks the looping task first by execution count" do
      get :dashboard
      offenders = controller.instance_variable_get(:@top_offenders)
      expect(offenders.first.task_id).to eq(task_a.id)
      expect(offenders.first.execution_count.to_i).to eq(5)
    end

    it "counts failed executions" do
      get :dashboard
      offenders = controller.instance_variable_get(:@top_offenders)
      task_b_row = offenders.find { |r| r.task_id == task_b.id }
      expect(task_b_row.failed_count.to_i).to eq(1)
    end

    it "detects rapid-fire patterns" do
      get :dashboard, params: { rapid_threshold: 10 }
      rapid = controller.instance_variable_get(:@rapid_fire)
      task_a_row = rapid.find { |r| r["task_id"] == task_a.id }
      expect(task_a_row).to be_present
      expect(task_a_row["rapid_count"].to_i).to eq(4)
      expect(task_a_row["min_gap"].to_f).to be_within(0.1).of(1.0)
    end

    it "excludes well-spaced tasks from rapid-fire" do
      get :dashboard, params: { rapid_threshold: 10 }
      rapid = controller.instance_variable_get(:@rapid_fire)
      expect(rapid.find { |r| r["task_id"] == task_b.id }).to be_nil
    end

    it "buckets executions in the histogram" do
      get :dashboard
      buckets = controller.instance_variable_get(:@histogram).pluck("bucket").uniq
      expect(buckets).not_to be_empty
    end

    it "honors the window parameter" do
      get :dashboard, params: { window: "7d" }
      expect(controller.instance_variable_get(:@window_key)).to eq("7d")
      expect(controller.instance_variable_get(:@bucket_seconds)).to eq(3600)
    end

    it "defaults to 1h for unknown windows" do
      get :dashboard, params: { window: "999d" }
      expect(controller.instance_variable_get(:@window_key)).to eq("1h")
    end

    context "when scoped to a single task" do
      it "scopes total count to that task only" do
        get :dashboard, params: { task_id: task_a.id }
        expect(controller.instance_variable_get(:@total_count)).to eq(5)
      end

      it "loads the task" do
        get :dashboard, params: { task_id: task_a.id }
        expect(controller.instance_variable_get(:@task)).to eq(task_a)
      end

      it "computes a status breakdown" do
        get :dashboard, params: { task_id: task_b.id }
        breakdown = controller.instance_variable_get(:@status_breakdown)
        expect(breakdown[Execution.statuses[:success]]).to eq(1)
        expect(breakdown[Execution.statuses[:failed]]).to eq(1)
      end

      it "computes an auth-type breakdown" do
        get :dashboard, params: { task_id: task_a.id }
        breakdown = controller.instance_variable_get(:@auth_breakdown)
        expect(breakdown[Execution.auth_types[:trigger]]).to eq(5)
      end

      it "skips top offenders aggregation" do
        get :dashboard, params: { task_id: task_a.id }
        expect(controller.instance_variable_get(:@top_offenders)).to eq([])
      end

      it "filters rapid-fire to the requested task only" do
        get :dashboard, params: { task_id: task_a.id, rapid_threshold: 10 }
        rapid = controller.instance_variable_get(:@rapid_fire)
        expect(rapid.pluck("task_id").uniq).to eq([task_a.id])
      end

      it "filters histogram to the requested task only" do
        get :dashboard, params: { task_id: task_b.id }
        histogram = controller.instance_variable_get(:@histogram)
        # task_b has only success + failed; no started or cancelled
        statuses = histogram.map { |r| r["status"].to_i }.uniq.sort
        expect(statuses).to eq([Execution.statuses[:success], Execution.statuses[:failed]].sort)
      end

      it "renders the per-task view" do
        get :dashboard, params: { task_id: task_a.id }
        expect(response.body).to include("Looper")
        expect(response.body).to include("Status breakdown")
        expect(response.body).to include("Trigger source")
        expect(response.body).not_to include("Top offenders")
      end

      it "rejects access to a task the user does not have access to" do
        other_task = Task.create!(user: other_user, name: "Other", listener: "tell:x", code: "// noop", enabled: true)
        get :dashboard, params: { task_id: other_task.id }
        expect(response).not_to be_successful
      end
    end
  end
end
