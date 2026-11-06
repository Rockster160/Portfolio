require "rails_helper"

RSpec.describe "Feature Builder webhooks", type: :request do
  let(:user) { User.me }

  describe "POST /webhooks/github" do
    let(:body) { JSON.generate({ "action" => "opened", "pull_request" => {} }) }

    before { DataStorage[FeatureBuilder::SECRET_KEY] = "shh" }

    def signed(payload, secret="shh")
      "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, payload)}"
    end

    def deliver(payload, signature:, event: "pull_request")
      post "/webhooks/github", params: payload, headers: {
        "Content-Type"        => "application/json",
        "X-GitHub-Event"      => event,
        "X-Hub-Signature-256" => signature,
      }
    end

    it "takes a delivery GitHub signed" do
      deliver(body, signature: signed(body))

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["outcome"]).to eq("ignored")
    end

    it "answers GitHub's ping" do
      deliver("{}", signature: signed("{}"), event: "ping")

      expect(response.parsed_body["outcome"]).to eq("pong")
    end

    it "turns away anything signed with another secret" do
      deliver(body, signature: signed(body, "guess"))

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /webhooks/byte/claude_sessions" do
    let(:audit) { user.byte_conversations.create!(name: ByteDailyAudit::NAME, mode: :claude) }

    before {
      allow(ByteLocal).to receive(:valid_secret?).and_return(false)
      allow(ByteLocal).to receive(:valid_secret?).with("shh").and_return(true)
    }

    def report(secret)
      post "/webhooks/byte/claude_sessions",
        params:  { machine: "mini", sessions: [{ conversation_id: audit.id, kind: "turn", working: true }] },
        as:      :json,
        headers: { "X-Byte-Secret" => secret }
    end

    it "puts the Mini's working sessions on the chip" do
      report("shh")

      expect(response).to have_http_status(:ok)
      expect(BackgroundProcess.live_find(user, FeatureBuilder::CHIP_KEY).name).to eq("Auditing…")
    end

    it "is turned away without the Mac's secret" do
      report("nope")

      expect(response).to have_http_status(:unauthorized)
      expect(BackgroundProcess.live_find(user, FeatureBuilder::CHIP_KEY)).to be_nil
    end
  end
end
