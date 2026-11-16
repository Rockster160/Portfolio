require "rails_helper"

RSpec.describe "GET /webhooks/byte/needs_you", type: :request do
  let(:user) { User.me }
  let(:pulls) { "https://github.com/Rockster160/Portfolio/pull" }

  before {
    allow(ByteLocal).to receive(:valid_secret?).and_return(false)
    allow(ByteLocal).to receive(:valid_secret?).with("shh").and_return(true)
  }

  def feature_build(title, **attrs)
    FeatureBuild.create!(user: user, title: title, request: title, status: :running, **attrs)
  end

  def production_script(title)
    ProductionScript.create!(
      user:       user,
      title:      title,
      code:       "1",
      commit_sha: "abc1234",
      edited_by:  :mini,
    )
  end

  it "lists PRs waiting on review, builds asking, and scripts waiting on approval" do
    review = feature_build("Bigger icons", pr_number: 41, pr_url: "#{pulls}/41")
    feature_build(
      "Approved already",
      pr_number:   42,
      pr_url:      "#{pulls}/42",
      approved_at: Time.current,
    )
    asking = feature_build(
      "Timer sounds",
      question: "Which sound?",
      asked_at: 1.hour.ago,
      rc_url:   "https://claude.ai/code/session_1",
    )
    feature_build("Still working")
    script = production_script("Add the yell")
    production_script("Ran already").update!(status: :succeeded)

    get "/webhooks/byte/needs_you", headers: { "X-Byte-Secret" => "shh" }

    expect(response.parsed_body["needs_you"]).to match([
      include("kind" => "pull", "title" => review.title, "url" => review.pr_url),
      include("kind" => "build", "title" => asking.title, "url" => asking.rc_url),
      include(
        "kind"   => "script",
        "title"  => script.title,
        "reason" => "Production script to approve",
        "url"    => a_string_ending_with("/system/production_scripts"),
      ),
    ])
  end

  it "turns away a request without the secret" do
    get "/webhooks/byte/needs_you", headers: { "X-Byte-Secret" => "guess" }

    expect(response).to have_http_status(:unauthorized)
  end
end
