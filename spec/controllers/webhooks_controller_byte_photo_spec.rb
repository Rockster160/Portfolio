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

    # The frame shape's `note` is written for a person and knows things this
    # side can't see — live vs pulled from a recording, how far off the
    # requested moment it landed. A ring with no body should say that rather
    # than fall through to the generic title.
    it "captions an uncaptioned frame with the note the shape carries" do
      meta = {
        ok:             true,
        camera:         "camera.doorbell_fluent",
        source:         "recording",
        captured_at:    "2026-08-24T12:03:21",
        event:          "person",
        off_by_seconds: 159,
        note:           "Frame from 12:03:21 PM on Aug 24 (person event).",
      }
      post :byte_photo, params: { files: [snapshot], metadata: meta.to_json }

      message = ByteMessage.order(:id).last
      expect(message.body).to eq("Frame from 12:03:21 PM on Aug 24 (person event).")
      expect(WebPushNotifications).to have_received(:send_to_byte).with(
        hash_including(title: "Frame from 12:03:21 PM on Aug 24 (person event)."),
      )
    end

    it "keeps an explicit caption over the note" do
      meta = { ok: true, note: "Frame from 12:03:21 PM on Aug 24 (person event)." }
      post :byte_photo, params: { files: [snapshot], body: "🔔 Someone's at the door", metadata: meta.to_json }

      expect(ByteMessage.order(:id).last.body).to eq("🔔 Someone's at the door")
    end

    it "keeps the whole frame shape on the message for later reading" do
      meta = {
        ok:             true,
        camera:         "camera.doorbell_fluent",
        source:         "live",
        requested:      "now",
        event:          "doorbell",
        off_by_seconds: 0,
        bytes:          397_994,
        shrunk:         nil,
      }
      post :byte_photo, params: { files: [snapshot], metadata: meta.to_json }

      stored = ByteMessage.order(:id).last.metadata
      expect(stored).to include(
        "camera" => "camera.doorbell_fluent", "event" => "doorbell",
        "requested" => "now", "bytes" => 397_994
      )
    end

    # Two vocabularies, one key. The audit reads `source` for provenance, so a
    # frame calling itself "live" must not take a doorbell photo out of it.
    it "keeps the frame's live-vs-recording sense without eating Byte's provenance" do
      meta = { ok: true, camera: "camera.doorbell_fluent", source: "recording" }
      post :byte_photo, params: { files: [snapshot], metadata: meta.to_json }

      stored = ByteMessage.order(:id).last.metadata
      expect(stored).to include("source" => "photo", "frame_source" => "recording")
    end

    it "leaves a hand-labelled source alone when there is no camera in the shape" do
      post :byte_photo, params: { files: [snapshot], metadata: { source: "hass" }.to_json }

      stored = ByteMessage.order(:id).last.metadata
      expect(stored).to include("source" => "hass")
      expect(stored).not_to have_key("frame_source")
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

  # A doorbell RING also reaches Chelsea — as one SHARED row rather than a
  # second copy, so both people are looking at the same frame and a reaction on
  # it is one reaction (ByteMessageShare).
  #
  # The payload shape is the real one, off log_tracker 4589106. She's a literal
  # id in the controller (there's no partner relation on User to derive her
  # from), so the spec stubs it rather than seeding user 58128 — an id that
  # collides with whatever the factory sequence happens to reach.
  describe "a doorbell ring" do
    let(:chelsea) { create(:user, username: "chelsea") }
    let(:bystander) { create(:user, username: "kiddo") }
    # User.me may already be in one, and ChoreHousehold auto-adds its owner —
    # creating a second would fail on the owner's own membership.
    let!(:household) { user.chore_household || ChoreHousehold.create!(name: "Home", owner_user: user) }
    let!(:hers) { chelsea.byte_conversations.create!(mode: :buddy, name: "Moss") }
    let!(:theirs) { bystander.byte_conversations.create!(mode: :buddy, name: "Glimmer") }

    before do
      [chelsea, bystander].each { |u|
        ChoreHouseholdMembership.create!(chore_household: household, user: u, role: :member)
        u.update!(chore_household_id: household.id)
      }
      user.update!(chore_household_id: household.id)
      stub_const("WebhooksController::DOORBELL_SHARE_USER_ID", chelsea.id)
    end

    def ring(extra={})
      meta = {
        camera:       "camera.doorbell_fluent",
        frame_source: "live",
        type:         "rang",
        subject:      "visitor",
        location:     "doorbell",
        rang:         true,
      }.merge(extra)
      post :byte_photo, params: { files: [snapshot], body: "🔔 Someone is at the door", metadata: meta.to_json }
    end

    it "shows her the same frame instead of posting a second one" do
      expect { ring }.to change(ByteMessage, :count).by(1)

      message = ByteMessage.order(:id).last
      expect(hers.visible_messages).to include(message)
      expect(hers.byte_messages).to be_empty
    end

    # It goes to HER, not to everyone under the roof. A doorbell at everybody is
    # a notification people learn to swipe away.
    it "shares with her and nobody else in the house" do
      expect { ring }.to change(ByteMessageShare, :count).by(1)

      expect(theirs.visible_messages).to be_empty
    end

    it "pushes it to her, not only to the screen" do
      expect(ByteNotifier).to receive(:notify).with(chelsea, anything)

      ring
    end

    it "addresses her broadcast to her own thread" do
      ring

      expect(MonitorChannel).to have_received(:broadcast_to).with(
        chelsea, hash_including(data: hash_including(message: hash_including(conversation_id: hers.id)))
      )
    end

    # The same camera reports a person merely SEEN — no ring. Waking someone for
    # a person walking past the door is the ping that got rejected in prod 3746,
    # in capitals.
    it "does not share a person the camera only saw" do
      expect {
        post :byte_photo, params: {
          files:    [snapshot],
          body:     "Someone out front",
          metadata: { camera: "camera.doorbell_fluent", location: "doorbell", subject: "person", detected: true }.to_json,
        }
      }.not_to change(ByteMessageShare, :count)
    end

    # The frame shape's own word for a ring. A payload carrying only that —
    # no `rang`, no `type` — is still a ring and still has to reach her.
    it "shares a ring the shape only labelled as a doorbell event" do
      expect {
        post :byte_photo, params: {
          files:    [snapshot],
          metadata: { camera: "camera.doorbell_fluent", location: "doorbell", event: "doorbell" }.to_json,
        }
      }.to change(ByteMessageShare, :count).by(1)
    end

    # Same camera, same key, the other meaning. `event: "person"` is somebody
    # SEEN at the door, which is the ping that got rejected in prod.
    it "does not share a person the shape labelled as a person event" do
      expect {
        post :byte_photo, params: {
          files:    [snapshot],
          metadata: { camera: "camera.doorbell_fluent", location: "doorbell", event: "person" }.to_json,
        }
      }.not_to change(ByteMessageShare, :count)
    end

    it "does not share a frame from another camera" do
      expect { ring(location: "driveway") }.not_to change(ByteMessageShare, :count)
    end

    it "does not share an ordinary photo with no metadata at all" do
      expect { post :byte_photo, params: { files: [snapshot] } }.not_to change(ByteMessageShare, :count)
    end

    # A hardcoded id is a row that can stop existing. A webhook is the wrong
    # place to raise about it — the picture still has to land for the person it
    # was posted for.
    it "still delivers the frame when the id points at nobody" do
      stub_const("WebhooksController::DOORBELL_SHARE_USER_ID", 0)

      expect { ring }.to change(ByteMessage, :count).by(1)
      expect(ByteMessageShare.count).to eq(0)
      expect(response).to have_http_status(:created)
    end

    # Posted for her in the first place: it's already in her thread, and a share
    # would show it to her twice.
    it "does not share it back to her when she's the one it was posted for" do
      stub_const("WebhooksController::DOORBELL_SHARE_USER_ID", user.id)

      expect { ring }.not_to change(ByteMessageShare, :count)
    end

    it "leaves the frame in the thread it was posted to" do
      ring

      expect(ByteMessage.order(:id).last.byte_conversation).to eq(buddy_convo)
    end
  end
end
