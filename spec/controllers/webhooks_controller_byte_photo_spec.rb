require "rails_helper"

# The doorbell path: Home Assistant posts the snapshot itself and it lands in
# the Buddy thread as a picture, with no model turn anywhere in the middle.
RSpec.describe WebhooksController, type: :controller do
  let(:user) { User.me }
  let!(:buddy_convo) { user.byte_conversations.create!(mode: :buddy, name: "Byte") }

  before do
    allow(ByteLocal).to receive(:valid_secret?).and_return(true)
    allow(MonitorChannel).to receive(:broadcast_to)
    allow(WebPushNotifications).to receive(:send_to_byte)
  end

  def snapshot(type: "image/jpeg", name: "doorbell.jpg", bytes: "pretend-jpeg")
    Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: name)
  end

  describe "POST #byte_photo" do
    it "posts the image into the Buddy thread as a delivered inbound message" do
      post :byte_photo, params: { files: [snapshot], body: "🔔 Someone's at the door" }

      expect(response).to have_http_status(:created)
      message = ByteMessage.order(:id).last
      expect(message.byte_conversation).to eq(buddy_convo)
      expect(message.direction).to eq("inbound")
      expect(message.state).to eq("delivered")
      expect(message.body).to eq("🔔 Someone's at the door")
      expect(message.files.attachments.size).to eq(1)
      expect(message.files.first.content_type).to eq("image/jpeg")
    end

    # The whole point of the endpoint. A snapshot that had to wait on a GPT call
    # is a snapshot of somebody who has already walked away.
    it "runs no model turn" do
      expect(BuddyDeliverWorker).not_to receive(:perform_async)
      expect(ByteLocal).not_to receive(:deliver)

      post :byte_photo, params: { files: [snapshot] }

      expect(response).to have_http_status(:created)
    end

    # `as_wire` is what the socket carries, and it reads `files`. Attaching
    # after the broadcast would put an empty bubble on the screen and never
    # broadcast that message again.
    it "broadcasts the message with its attachment already on it" do
      payloads = []
      allow(MonitorChannel).to receive(:broadcast_to) { |_u, payload| payloads << payload }

      post :byte_photo, params: { files: [snapshot] }

      wire = payloads.last.dig(:data, :message)
      expect(wire[:attachments].length).to eq(1)
      expect(wire[:attachments].first[:content_type]).to eq("image/jpeg")
    end

    it "pushes with the caption, so the lock screen says which door" do
      post :byte_photo, params: { files: [snapshot], body: "🔔 Someone's at the door" }

      expect(WebPushNotifications).to have_received(:send_to_byte).with(
        hash_including(title: "🔔 Someone's at the door"),
      )
    end

    it "still pushes something when the picture arrives with no caption" do
      post :byte_photo, params: { files: [snapshot] }

      expect(ByteMessage.order(:id).last.body).to eq("")
      expect(WebPushNotifications).to have_received(:send_to_byte).with(
        hash_including(title: "📷 New photo"),
      )
    end

    it "renders as the pet speaking rather than as a silent row" do
      post :byte_photo, params: { files: [snapshot] }

      expect(ByteMessage.order(:id).last.metadata).to include("kind" => "buddy", "source" => "photo")
    end

    it "lets the caller label where the picture came from" do
      post :byte_photo, params: { files: [snapshot], metadata: { source: "hass" }.to_json }

      expect(ByteMessage.order(:id).last.metadata).to include("source" => "hass")
    end

    # An unmarked thread resolves to the oldest Buddy one — the same rule a
    # reminder or a watch follows. The owner's claude thread is not where "show
    # me the door" belongs.
    it "picks the self-initiated Buddy thread over a claude one" do
      user.byte_conversations.create!(mode: :claude, name: "Claude")

      post :byte_photo, params: { files: [snapshot] }

      expect(ByteMessage.order(:id).last.byte_conversation).to eq(buddy_convo)
    end

    it "honors an explicit conversation_id" do
      other = user.byte_conversations.create!(mode: :buddy, name: "Kitchen")

      post :byte_photo, params: { files: [snapshot], conversation_id: other.id }

      expect(ByteMessage.order(:id).last.byte_conversation).to eq(other)
    end

    it "refuses a caller without the shared secret" do
      allow(ByteLocal).to receive(:valid_secret?).and_return(false)

      expect { post :byte_photo, params: { files: [snapshot] } }.not_to change(ByteMessage, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    describe "authenticating with an API key instead of the shared secret" do
      let(:other) { create(:user) }
      let(:api_key) { user.api_keys.create!(name: "Home Assistant") }

      before { allow(ByteLocal).to receive(:valid_secret?).and_return(false) }

      def authenticate(key)
        request.headers["Authorization"] = "Bearer #{key}"
      end

      it "accepts a valid key and posts into that key's own Buddy thread" do
        authenticate(api_key.key)

        post :byte_photo, params: { files: [snapshot], body: "🔔 Someone's at the door" }

        expect(response).to have_http_status(:created)
        message = ByteMessage.order(:id).last
        expect(message.byte_conversation).to eq(buddy_convo)
        expect(message.files.attachments.size).to eq(1)
      end

      it "stamps the key as used, so a stale one is visible on the keys page" do
        authenticate(api_key.key)

        expect { post :byte_photo, params: { files: [snapshot] } }
          .to change { api_key.reload.last_used_at }.from(nil)
      end

      # A key is a person, not authority over the house. The shared secret is
      # what speaks for somebody else.
      it "ignores a user_id naming somebody else" do
        other_convo = other.byte_conversations.create!(mode: :buddy, name: "Byte")

        authenticate(api_key.key)
        post :byte_photo, params: { files: [snapshot], user_id: other.id }

        expect(other_convo.byte_messages.count).to eq(0)
        expect(ByteMessage.order(:id).last.byte_conversation).to eq(buddy_convo)
      end

      it "refuses a key nobody issued" do
        authenticate("NOT-A-REAL-KEY")

        expect { post :byte_photo, params: { files: [snapshot] } }.not_to change(ByteMessage, :count)
        expect(response).to have_http_status(:unauthorized)
      end

      it "refuses a key that's been disabled" do
        api_key.update!(enabled: false)
        authenticate(api_key.key)

        expect { post :byte_photo, params: { files: [snapshot] } }.not_to change(ByteMessage, :count)
        expect(response).to have_http_status(:unauthorized)
      end

      # This controller skips CSRF verification. If a session cookie were enough
      # here, any page they happened to be looking at could post into the thread.
      it "refuses a signed-in session with no Authorization header" do
        sign_in user

        expect { post :byte_photo, params: { files: [snapshot] } }.not_to change(ByteMessage, :count)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "refuses a request carrying no image, rather than posting an empty bubble" do
      expect { post :byte_photo, params: { body: "🔔 Someone's at the door" } }.not_to change(ByteMessage, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/no file/i)
    end

    it "refuses a file that isn't an image" do
      expect {
        post :byte_photo, params: { files: [snapshot(type: "application/pdf", name: "doc.pdf")] }
      }.not_to change(ByteMessage, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/unsupported/i)
    end

    it "refuses an oversized image" do
      stub_const("ByteMessage::MAX_UPLOAD_BYTES", 1)

      expect {
        post :byte_photo, params: { files: [snapshot(bytes: "several-bytes")] }
      }.not_to change(ByteMessage, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/too large/i)
    end
  end
end
