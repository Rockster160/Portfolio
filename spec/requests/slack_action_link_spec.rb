require "rails_helper"

RSpec.describe "Tapping a Slack action link", type: :request do
  let(:user) { User.me }
  let(:other) { create(:user) }

  def sign_in_as(target)
    post login_path, params: { user: { username: target.username, password: "password123" } }
  end

  around { |example|
    kept = Slack::Actions.registry.dup
    example.run
    Slack::Actions.registry.replace(kept)
  }

  before do
    user.update!(password: "password123", password_confirmation: "password123")
    Slack::Actions.register(:spec_thing, label: "Do it", run: ->(p) { "ran with #{p[:id]}" })
  end

  it "runs the handler and shows what it said" do
    sign_in_as(user)

    get "/slack/action/spec_thing", params: { id: 7 }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("ran with 7")
  end

  # The link carries no secret of its own, so the session is the whole gate —
  # a forwarded Slack message must not hand anyone else the controls.
  it "is 404 for anyone else" do
    other.update!(password: "password123", password_confirmation: "password123")
    sign_in_as(other)

    get "/slack/action/spec_thing"

    expect(response).to have_http_status(:not_found)
  end

  it "is 404 signed out" do
    get "/slack/action/spec_thing"

    expect(response).not_to have_http_status(:ok)
  end
end
