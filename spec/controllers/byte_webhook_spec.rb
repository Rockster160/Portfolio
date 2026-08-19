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

    # Prod 3946, the daily audit. It came back naming conversation 26 (Moss)
    # with an in_reply_to of 1133 — a fan command from three weeks earlier in
    # conversation 21 — while the prompt it was answering sat in 37. Both hints
    # the Mac sent were wrong, and the explicit one won, so a full engineering
    # report was published inside a companion thread with no prompt above it.
    describe "routing a reply the Mac has mis-addressed" do
      # The account shape in prod: the main thread IS a companion — Byte is a
      # pet, thread 21, the primary one — and Moss is a second companion beside
      # it. `home` first, so it is the older id and therefore the primary.
      let!(:home) {
        user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: 2.hours.ago)
      }
      let!(:moss) {
        user.byte_conversations.create!(mode: :buddy, name: "Moss", last_message_at: Time.current)
      }

      before do
        allow(MonitorChannel).to receive(:broadcast_to)
        allow(WebPushNotifications).to receive(:send_to_byte)
      end

      def landed_in(params)
        post(:byte_create, params: { user_id: user.id, body: "Read the whole window." }.merge(params))
        user.byte_messages.inbound.last.byte_conversation
      end

      it "refuses a companion thread even when named outright" do
        expect(landed_in(conversation_id: moss.id)).to eq(home)
      end

      it "refuses one reached through an in_reply_to into a companion thread" do
        stale = moss.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "hi")

        expect(landed_in(in_reply_to: stale.id)).to eq(home)
      end

      # 4002 named message 1194, a thank-you from three weeks earlier. A reply
      # answers something just said; anything older is the Mac replaying state.
      it "ignores an in_reply_to pointing weeks into the past" do
        old = user.byte_conversations.create!(mode: :claude, name: "OCS", last_message_at: 3.weeks.ago)
        ancient = old.byte_messages.create!(
          user: user, direction: :outbound, state: :sent, body: "Turn the fan to high, please",
          created_at: 3.weeks.ago,
        )

        expect(landed_in(in_reply_to: ancient.id)).to eq(home)
      end

      it "still follows a fresh one" do
        other = user.byte_conversations.create!(mode: :claude, name: "OCS", last_message_at: Time.current)
        asked = other.byte_messages.create!(user: user, direction: :outbound, state: :sent, body: "audit this")

        expect(landed_in(in_reply_to: asked.id)).to eq(other)
      end

      # The rule is about companion threads, not about distrusting the Mac.
      it "still honors a thread it is allowed to write into" do
        other = user.byte_conversations.create!(mode: :claude, name: "OCS", last_message_at: 1.day.ago)

        expect(landed_in(conversation_id: other.id)).to eq(other)
      end

      # Prod 4005: `byte "alert"` from the CLI landed in Memory, a Claude thread
      # that happened to be the newest on the account, because the fallback
      # looked for a NON-companion thread named Byte and the real one is a
      # companion. Every `byte "..."` before it had gone to thread 21.
      it "falls back to the primary thread rather than to whatever was most recent" do
        newest = user.byte_conversations.create!(
          mode: :claude, name: "Memory", last_message_at: 1.minute.from_now,
        )

        expect(landed_in({})).to eq(home)
        expect(newest.byte_messages.count).to eq(0)
      end

      it "follows the primary flag when it moves off the oldest thread" do
        ByteConversation.pin_primary!(moss)

        expect(landed_in({})).to eq(moss)
      end
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

    it "titles the push with the message itself, not the thread name" do
      captured = nil
      allow(WebPushNotifications).to receive(:send_to_byte) { |payload| captured = payload }

      patch :byte_update, params: { id: message.id, body: "It's a good time for dishes", state: "delivered" }

      expect(captured[:title]).to eq("It's a good time for dishes")
      expect(captured[:body]).to be_nil
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
