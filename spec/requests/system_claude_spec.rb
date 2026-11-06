require "rails_helper"

RSpec.describe "Claude on the Mini page", type: :request do
  let(:user) { User.me }
  let!(:build) {
    FeatureBuild.create!(
      user:      user,
      title:     "Dark mode",
      request:   "dark mode",
      status:    :running,
      branch:    "feature-builder/1-dark-mode",
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

  it "lists what's running and every build with its links" do
    FeatureBuilder.report_sessions!(machine: :mini, sessions: [
      { "build_id" => build.id, "kind" => "builder", "working" => false },
    ])

    get system_claude_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Dark mode", "waiting on you", "feature-builder/1-dark-mode")
    expect(response.body).to include("https://claude.ai/code/session_abc", "PR #42")
  end

  it "says so when nothing is running" do
    get system_claude_path

    expect(response.body).to include("Nothing is running on Portfolio on the Mini.")
  end

  it "lists the plans and PRs waiting on the owner" do
    FeatureBuild.create!(
      user:       user,
      title:      "Repeating timers",
      request:    "repeating timers",
      status:     :running,
      planned_at: 1.hour.ago,
      rc_url:     "https://claude.ai/code/session_plan",
    )

    get system_claude_path

    expect(response.body).to include("Waiting on you", "Repeating timers", "plan ready", "PR open")
    expect(response.body).to include("https://claude.ai/code/session_plan")
  end

  it "opens the questions session in Claude" do
    stub_request(:post, %r{/byte/builder\z}).with(
      body: hash_including("action" => "questions"),
    ).to_return(status: 200, body: { ok: true, rc_url: "https://claude.ai/code/session_q" }.to_json)

    post system_claude_questions_path

    expect(response).to redirect_to("https://claude.ai/code/session_q")
  end

  it "says so when the Mini can't open the questions session" do
    stub_request(:post, %r{/byte/builder\z}).to_return(status: 502, body: { ok: false }.to_json)

    post system_claude_questions_path

    expect(response).to redirect_to(system_claude_path)
    expect(flash[:notice]).to include("didn't hand back a Claude session")
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
