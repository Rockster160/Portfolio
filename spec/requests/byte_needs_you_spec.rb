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

  it "lists approved PRs in the order they merge, leaving out the held and the one merging" do
    later = feature_build(
      "Car boot",
      pr_number:      100,
      pr_url:         "#{pulls}/100",
      queue_position: 3,
      approved_at:    1.minute.ago,
    )
    sooner = feature_build(
      "Bigger icons",
      pr_number:      98,
      pr_url:         "#{pulls}/98",
      queue_position: 2,
      approved_at:    2.minutes.ago,
    )
    feature_build(
      "Generate images",
      pr_number:      99,
      pr_url:         "#{pulls}/99",
      queue_position: 1,
      approved_at:    3.minutes.ago,
      landing_at:     Time.current,
    )
    feature_build(
      "Set aside",
      pr_number:      97,
      pr_url:         "#{pulls}/97",
      queue_position: 4,
      approved_at:    4.minutes.ago,
      held:           true,
    )
    feature_build("In review", pr_number: 96, pr_url: "#{pulls}/96", queue_position: 5)

    get "/webhooks/byte/needs_you", headers: { "X-Byte-Secret" => "shh" }

    expect(response.parsed_body["upcoming"]).to match([
      include("kind" => "Merge", "ticket" => 98, "title" => sooner.title, "url" => sooner.pr_url),
      include("kind" => "Merge", "ticket" => 100, "title" => later.title, "url" => later.pr_url),
    ])
  end

  it "carries the Claude plan's usage as the status line last reported it, and nil before any report" do
    get "/webhooks/byte/needs_you", headers: { "X-Byte-Secret" => "shh" }
    expect(response.parsed_body["claude"]).to be_nil

    reported = { seven_day: { used: 83, resets_at: 1_795_266_000, observed_at: 1_795_216_725 } }
    user.caches.set(:claude_usage, reported.to_json)

    get "/webhooks/byte/needs_you", headers: { "X-Byte-Secret" => "shh" }
    expect(response.parsed_body["claude"]).to eq(reported.deep_stringify_keys)
  end

  it "turns away a request without the secret" do
    get "/webhooks/byte/needs_you", headers: { "X-Byte-Secret" => "guess" }

    expect(response).to have_http_status(:unauthorized)
  end
end
