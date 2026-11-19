require "rails_helper"

RSpec.describe "/webhooks/byte/pulls", type: :request do
  let(:user) { User.me }
  let(:hass) { "Rockster160/hass-config" }
  let(:headers) { { "X-Byte-Secret" => "shh" } }

  before {
    allow(ByteLocal).to receive(:valid_secret?).and_return(false)
    allow(ByteLocal).to receive(:valid_secret?).with("shh").and_return(true)
  }

  def merged(title, repo:, sha:, **attrs)
    FeatureBuild.create!(
      user:        user,
      title:       title,
      request:     title,
      repo:        repo,
      status:      :finished,
      finished_at: Time.current,
      merge_sha:   sha,
      **attrs,
    )
  end

  it "lists the merges in a repo the laptop has still to pull, and clears the ones it has" do
    porch = merged("Porch light", repo: hass, sha: "aaa111")
    garage = merged("Garage sensor", repo: hass, sha: "bbb222")
    merged("Pulled already", repo: hass, sha: "ccc333", pulled_at: 1.day.ago)
    merged("Deployed", repo: FeatureBuilder::Repos::PORTFOLIO, sha: "ddd444")
    merged("Other repo", repo: "Rockster160/slime-civ", sha: "eee555")

    get "/webhooks/byte/pulls", params: { repo: hass }, headers: headers

    expect(response.parsed_body["shas"]).to contain_exactly("aaa111", "bbb222")

    post "/webhooks/byte/pulls", params: { repo: hass, shas: ["aaa111", "fff666"] }, headers: headers, as: :json

    expect(response.parsed_body["pulled"]).to eq([porch.id])
    expect(porch.reload.pulled_at).to be_present
    expect(garage.reload.pulled_at).to be_nil
  end

  it "turns away a request without the secret" do
    get "/webhooks/byte/pulls", params: { repo: hass }, headers: { "X-Byte-Secret" => "guess" }

    expect(response).to have_http_status(:unauthorized)
  end
end
