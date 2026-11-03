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

    def ivar(name) = controller.instance_variable_get(name)

    it "summarises the current user's executions: totals, offenders, failures, histogram", :aggregate_failures do
      get :dashboard

      expect(response).to be_successful
      expect(response.body).to include("histogram-data")
      expect(ivar(:@total_count)).to eq(7)
      offenders = ivar(:@top_offenders)
      expect(offenders.first.task_id).to eq(task_a.id)
      expect(offenders.first.execution_count.to_i).to eq(5)
      expect(offenders.find { |r| r.task_id == task_b.id }.failed_count.to_i).to eq(1)
      expect(ivar(:@histogram).pluck("bucket").uniq).not_to be_empty
    end

    it "detects rapid-fire patterns and leaves well-spaced tasks out", :aggregate_failures do
      get :dashboard, params: { rapid_threshold: 10 }
      rapid = ivar(:@rapid_fire)
      task_a_row = rapid.find { |r| r["task_id"] == task_a.id }
      expect(task_a_row["rapid_count"].to_i).to eq(4)
      expect(task_a_row["min_gap"].to_f).to be_within(0.1).of(1.0)
      expect(rapid.find { |r| r["task_id"] == task_b.id }).to be_nil
    end

    it "honors the window parameter, defaulting to 1h for unknown windows" do
      get :dashboard, params: { window: "7d" }
      expect(ivar(:@window_key)).to eq("7d")
      expect(ivar(:@bucket_seconds)).to eq(3600)

      get :dashboard, params: { window: "999d" }
      expect(ivar(:@window_key)).to eq("1h")
    end

    context "when scoped to a single task" do
      it "scopes counts, breakdowns and rapid-fire to that task and skips offenders", :aggregate_failures do
        get :dashboard, params: { task_id: task_a.id, rapid_threshold: 10 }

        expect(ivar(:@task)).to eq(task_a)
        expect(ivar(:@total_count)).to eq(5)
        expect(ivar(:@auth_breakdown)[Execution.auth_types[:trigger]]).to eq(5)
        expect(ivar(:@top_offenders)).to eq([])
        expect(ivar(:@rapid_fire).pluck("task_id").uniq).to eq([task_a.id])
        expect(response.body).to include("Looper")
      end

      it "breaks down status and filters the histogram to the task", :aggregate_failures do
        get :dashboard, params: { task_id: task_b.id }

        breakdown = ivar(:@status_breakdown)
        expect(breakdown[Execution.statuses[:success]]).to eq(1)
        expect(breakdown[Execution.statuses[:failed]]).to eq(1)
        statuses = ivar(:@histogram).map { |r| r["status"].to_i }.uniq.sort
        expect(statuses).to eq([Execution.statuses[:success], Execution.statuses[:failed]].sort)
      end

      it "rejects access to a task the user does not have access to" do
        other_task = Task.create!(user: other_user, name: "Other", listener: "tell:x", code: "// noop", enabled: true)
        get :dashboard, params: { task_id: other_task.id }
        expect(response).not_to be_successful
      end
    end

    context "when admin views scope=all" do
      let(:admin) { FactoryBot.create(:user, phone: "5550000099", role: :admin) }
      before { sign_in admin }

      it "includes other users' executions, tasks and owners", :aggregate_failures do
        get :dashboard, params: { scope: "all" }
        expect(ivar(:@view_scope)).to eq(:all)
        expect(ivar(:@total_count)).to eq(8)
        expect(ivar(:@top_offenders).map(&:task_id)).to include(task_a.id, task_b.id)
        expect(ivar(:@user_lookup)[user.id]).to eq(user)
      end

      it "allows drilling into a task the admin does not own" do
        get :dashboard, params: { scope: "all", task_id: task_a.id }
        expect(response).to be_successful
        expect(ivar(:@task)).to eq(task_a)
      end
    end

    context "when non-admin passes scope=all" do
      it "ignores the param and stays scoped to the current user" do
        get :dashboard, params: { scope: "all" }
        expect(ivar(:@view_scope)).to eq(:mine)
        expect(ivar(:@total_count)).to eq(7)
      end
    end
  end
end
