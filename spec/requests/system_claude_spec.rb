require "rails_helper"

RSpec.describe "Claude on the Mini page", type: :request do
  let(:user) { User.me }
  let!(:build) {
    FeatureBuild.create!(
      user:      user,
      title:     "Dark mode",
      request:   "dark mode",
      status:    :running,
      branch:    "byte/1-dark-mode",
      rc_url:    "https://claude.ai/code/session_abc",
      pr_number: 42,
      pr_url:    "https://github.com/Rockster160/Portfolio/pull/42",
    )
  }

  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before { sign_in }

  it "lists past builds with their branch and PR" do
    build.update!(status: :finished)

    get system_claude_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Feature builds", "Dark mode", "byte/1-dark-mode", "PR #42")
  end

  it "lists a build once, in the first section that has it" do
    FeatureBuilder.report_sessions!(machine: :mini, sessions: [
      { "build_id" => build.id, "kind" => "builder", "working" => false },
    ])

    get system_claude_path

    expect(response.body).to include("Waiting on you", "PR open")
    expect(response.body.scan("Dark mode").length).to eq(1)
    expect(response.body).to include("Nothing is running on Portfolio on the Mini.")
  end

  it "lists a working build under running, not again in the history" do
    build.update!(pr_url: nil, pr_number: nil)
    FeatureBuilder.report_sessions!(machine: :mini, sessions: [
      { "build_id" => build.id, "kind" => "builder", "working" => true },
    ])

    get system_claude_path

    expect(response.body).to include("Running now", "working", "Stop")
    expect(response.body.scan("Dark mode").length).to eq(1)
  end

  it "says so when nothing is running" do
    get system_claude_path

    expect(response.body).to include("Nothing is running on Portfolio on the Mini.")
  end

  it "lists a build waiting on an answer" do
    FeatureBuild.create!(user: user, title: "Bigger icons", request: "bigger icons", status: :running).tap { |asking|
      FeatureBuilder.report_sessions!(machine: :mini, sessions: [
        { "build_id" => asking.id, "kind" => "builder", "working" => false },
      ])
    }

    get system_claude_path

    expect(response.body).to include("Waiting on you", "Bigger icons")
  end

  it "lists the PRs waiting on the owner, and not a plan it's building from" do
    planned = FeatureBuild.create!(
      user:       user,
      title:      "Repeating timers",
      request:    "repeating timers",
      status:     :running,
      planned_at: 1.hour.ago,
      rc_url:     "https://claude.ai/code/session_plan",
    )
    FeatureBuilder.report_sessions!(machine: :mini, sessions: [
      { "build_id" => planned.id, "kind" => "builder", "working" => true },
    ])

    get system_claude_path

    expect(response.body).to include("Waiting on you", "PR open", "building", "Repeating timers")
    expect(response.body).not_to include("plan ready")
  end

  it "opens the questions session in Claude" do
    stub_request(:post, %r{/byte/builder\z}).with(
      body: hash_including("action" => "questions"),
    ).to_return(status: 200, body: { ok: true, rc_url: "https://claude.ai/code/session_q" }.to_json)

    post system_claude_questions_path

    expect(response).to redirect_to("https://claude.ai/code/session_q")
  end

  describe "when the questions session can't be opened" do
    it "passes on why Claude didn't come up" do
      stub_request(:post, %r{/byte/builder\z}).to_return(
        status: 502,
        body:   { ok: false, error: "Claude exited before it was ready" }.to_json,
      )

      post system_claude_questions_path

      expect(response).to redirect_to(system_claude_path)
      expect(flash[:notice]).to eq("Claude didn't come up on the Mini: Claude exited before it was ready")
    end

    it "says Byte needs a restart when it doesn't know the action" do
      stub_request(:post, %r{/byte/builder\z}).to_return(
        status: 404,
        body:   { ok: false, error: "no build 0 here" }.to_json,
      )

      post system_claude_questions_path

      expect(flash[:notice]).to include("older code", "Restart it")
    end

    it "says the Mini didn't answer when it can't be reached" do
      stub_request(:post, %r{/byte/builder\z}).to_raise(Errno::ECONNREFUSED)

      post system_claude_questions_path

      expect(flash[:notice]).to include("The Mini didn't answer")
    end
  end

  it "asks the Mini to close a build's session" do
    stop = stub_request(:post, %r{/byte/builder\z}).with(
      body: hash_including("action" => "stop", "build_id" => build.id),
    ).to_return(status: 200, body: "{}")

    post system_claude_stop_path(id: build.id)

    expect(stop).to have_been_requested
    expect(build.reload).to be_status_stopped
    expect(response).to redirect_to(system_claude_path)
  end
end
