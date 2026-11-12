require "rails_helper"

RSpec.describe "Feature Builder webhooks", type: :request do
  let(:user) { User.me }

  describe "POST /webhooks/github" do
    let(:body) { JSON.generate({ "action" => "labeled", "pull_request" => {} }) }

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

  describe "POST /webhooks/byte/builds" do
    let!(:primary) { user.byte_conversations.create!(mode: :buddy, last_message_at: Time.current) }

    before {
      allow(ByteLocal).to receive(:valid_secret?).and_return(false)
      allow(ByteLocal).to receive(:valid_secret?).with("shh").and_return(true)
      allow(FeatureBuildStartWorker).to receive(:perform_async)
    }

    def hand_over(params, secret: "shh")
      post "/webhooks/byte/builds", params: params, as: :json, headers: { "X-Byte-Secret" => secret }
    end

    it "starts a build with the brief, speaking in the primary Buddy thread" do
      hand_over({ title: "Questions can build", request: "Add /feature to the Questions session." })

      expect(response).to have_http_status(:ok)
      build = FeatureBuild.find(response.parsed_body["id"])
      expect(build.title).to eq("Questions can build")
      expect(build.request).to eq("Add /feature to the Questions session.")
      expect(build.user).to eq(user)
      expect(build.byte_conversation).to eq(primary)
      expect(build.byte_message.body).to include("Starting a Feature Builder")
      expect(FeatureBuildStartWorker).to have_received(:perform_async).with(build.id)
    end

    it "names it from the brief when no title is given" do
      hand_over({ request: "Dark mode for lists\n\nMore detail." })

      expect(FeatureBuild.last.title).to eq("Dark mode for lists")
    end

    it "turns away an empty brief" do
      expect { hand_over({ title: "Nothing", request: "  " }) }.not_to change(FeatureBuild, :count)

      expect(response).to have_http_status(:bad_request)
    end

    it "is turned away without the Mac's secret" do
      expect { hand_over({ request: "Dark mode" }, secret: "guess") }.not_to change(FeatureBuild, :count)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "PATCH /webhooks/byte/builds/:id" do
    let(:build) { FeatureBuild.create!(user: user, title: "Dark mode", request: "dark mode") }

    before {
      allow(ByteLocal).to receive(:valid_secret?).and_return(false)
      allow(ByteLocal).to receive(:valid_secret?).with("shh").and_return(true)
    }

    it "takes the Mini's word on how a build is going" do
      patch "/webhooks/byte/builds/#{build.id}",
        params:  { status: "running", rc_url: "https://claude.ai/code/session_abc", user_id: 99 },
        as:      :json,
        headers: { "X-Byte-Secret" => "shh" }

      expect(response).to have_http_status(:ok)
      expect(build.reload).to be_status_running
      expect(build.rc_url).to eq("https://claude.ai/code/session_abc")
      expect(build.user).to eq(user)
    end

    it "is turned away without the Mac's secret" do
      patch "/webhooks/byte/builds/#{build.id}", params: { status: "failed" }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(build.reload).to be_status_starting
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
