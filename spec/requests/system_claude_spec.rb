require "rails_helper"

RSpec.describe "Claude on the Mini page", type: :request do
  let(:user) { User.me }
  let!(:builder) {
    user.byte_conversations.create!(
      name:     "Dark mode",
      mode:     :builder,
      metadata: {
        "builder" => {
          "branch" => "feature-builder/1-dark-mode",
          "rc_url" => "https://claude.ai/code/session_abc",
          "pr_url" => "https://github.com/Rockster160/Portfolio/pull/42",
        },
      },
    )
  }

  def sign_in
    user.update!(password: "password123", password_confirmation: "password123")
    post login_path, params: { user: { username: user.username, password: "password123" } }
  end

  before { sign_in }

  it "lists what's running and every builder with its links" do
    FeatureBuilder.report_sessions!(machine: :mini, sessions: [
      { "conversation_id" => builder.id, "kind" => "builder", "working" => false },
    ])

    get system_claude_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Dark mode", "waiting on you", "feature-builder/1-dark-mode")
    expect(response.body).to include("https://claude.ai/code/session_abc", "/pull/42")
  end

  it "says so when nothing is running" do
    get system_claude_path

    expect(response.body).to include("Nothing is running on Portfolio on the Mini.")
  end

  it "asks the Mini to close a builder's session" do
    stop = stub_request(:post, %r{/byte/builder\z}).with(
      body: hash_including("action" => "stop", "conversation_id" => builder.id),
    ).to_return(status: 200, body: "{}")

    post system_claude_stop_path(conversation_id: builder.id)

    expect(stop).to have_been_requested
    expect(response).to redirect_to(system_claude_path)
  end
end
