require "rails_helper"

RSpec.describe WebhooksController, type: :controller do
  let(:user)   { User.me }
  let(:secret) { "test-secret" }

  before do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("BYTE_LOCAL_SECRET", "").and_return(secret)
    request.env["HTTP_X_BYTE_SECRET"] = secret
  end

  describe "POST #byte_create (simple JSON — backward compatible)" do
    it "creates an inbound message, broadcasts, and pushes on :delivered" do
      expect(MonitorChannel).to receive(:broadcast_to).with(user, hash_including(channel: :byte))
      expect(WebPushNotifications).to receive(:send_to_byte).with(hash_including(users: [user]))

      expect {
        post :byte_create, params: { user_id: user.id, in_reply_to: 42, body: "Got: hello", metadata: { handler: "placeholder" } }
      }.to change { user.byte_messages.inbound.count }.by(1)

      expect(response).to be_successful
      msg = user.byte_messages.inbound.last
      expect(msg.body).to eq("Got: hello")
      expect(msg.metadata["in_reply_to"].to_s).to eq("42")
      expect(msg).to be_delivered
    end

    it "starts in :streaming state without firing a push notification" do
      expect(MonitorChannel).to receive(:broadcast_to)
      expect(WebPushNotifications).not_to receive(:send_to_byte)

      post :byte_create, params: { user_id: user.id, body: "typing…", state: "streaming" }

      msg = user.byte_messages.inbound.last
      expect(msg).to be_streaming
      expect(msg.delivered_at).to be_nil
    end

    it "401s without the shared secret" do
      request.env["HTTP_X_BYTE_SECRET"] = "wrong"
      post :byte_create, params: { user_id: user.id, body: "nope" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "400s an empty body with no attachments" do
      post :byte_create, params: { user_id: user.id, body: "" }
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "POST #byte_create with multipart attachments" do
    let(:image) {
      Rack::Test::UploadedFile.new(
        StringIO.new("pretend-png-bytes"),
        "image/png",
        original_filename: "chart.png",
      )
    }

    it "attaches the file, allows empty body, and includes attachments in the broadcast" do
      broadcasted = nil
      allow(MonitorChannel).to receive(:broadcast_to) { |_u, payload| broadcasted = payload }
      allow(WebPushNotifications).to receive(:send_to_byte)

      post :byte_create, params: { user_id: user.id, body: "", files: [image] }

      expect(response).to be_successful
      msg = user.byte_messages.inbound.last
      expect(msg.files.count).to eq(1)
      expect(msg.files.first.filename.to_s).to eq("chart.png")

      wire = broadcasted.dig(:data, :message)
      expect(wire[:attachments].size).to eq(1)
      expect(wire[:attachments].first).to include(content_type: "image/png", filename: "chart.png")
    end
  end

  describe "PATCH #byte_update (streaming + late attachments)" do
    let!(:message) {
      user.byte_messages.create!(
        direction: :inbound, state: :streaming, body: "hel", metadata: { source: "ai" },
      )
    }

    it "appends body, keeps other metadata, and stays silent while streaming" do
      expect(MonitorChannel).to receive(:broadcast_to)
      expect(WebPushNotifications).not_to receive(:send_to_byte)

      patch :byte_update, params: {
        id:       message.id,
        body:     "hello world",
        state:    "streaming",
        metadata: { chunks: 5 },
      }

      message.reload
      expect(message.body).to eq("hello world")
      expect(message).to be_streaming
      # Form params stringify — metadata is opaque jsonb, so we don't coerce.
      expect(message.metadata).to include("source" => "ai", "chunks" => "5")
    end

    it "fires a push notification on the transition to :delivered" do
      expect(WebPushNotifications).to receive(:send_to_byte)

      patch :byte_update, params: { id: message.id, body: "hello world done", state: "delivered" }

      message.reload
      expect(message).to be_delivered
      expect(message.delivered_at).to be_present
    end

    it "attaches files on update" do
      allow(MonitorChannel).to receive(:broadcast_to)
      image = Rack::Test::UploadedFile.new(StringIO.new("bytes"), "image/png", original_filename: "late.png")

      patch :byte_update, params: { id: message.id, state: "delivered", files: [image] }

      message.reload
      expect(message.files.count).to eq(1)
      expect(message.files.first.filename.to_s).to eq("late.png")
    end

    it "404s an unknown id" do
      patch :byte_update, params: { id: 999_999, body: "x" }
      expect(response).to have_http_status(:not_found)
    end

    it "401s without the shared secret" do
      request.env["HTTP_X_BYTE_SECRET"] = "wrong"
      patch :byte_update, params: { id: message.id, body: "x" }
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
