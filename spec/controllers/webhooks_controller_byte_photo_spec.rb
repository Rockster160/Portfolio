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
    # No model turn: a snapshot that had to wait on a GPT call is a snapshot of
    # somebody who has already walked away. `as_wire` reads `files`, so the
    # attachment has to be on the message before it is broadcast.
    it "posts the image into the Buddy thread as the pet speaking, broadcast and pushed with its caption", :aggregate_failures do
      payloads = []
      allow(MonitorChannel).to receive(:broadcast_to) { |_u, payload| payloads << payload }
      expect(BuddyDeliverWorker).not_to receive(:perform_async)
      expect(ByteLocal).not_to receive(:deliver)

      post :byte_photo, params: { files: [snapshot], body: "🔔 Someone's at the door" }

      expect(response).to have_http_status(:created)
      message = ByteMessage.order(:id).last
      expect(message.byte_conversation).to eq(buddy_convo)
      expect(message.direction).to eq("inbound")
      expect(message.state).to eq("delivered")
      expect(message.body).to eq("🔔 Someone's at the door")
      expect(message.files.attachments.size).to eq(1)
      expect(message.files.first.content_type).to eq("image/jpeg")
      expect(message.metadata).to include("kind" => "buddy", "source" => "photo")

      wire = payloads.last.dig(:data, :message)
      expect(wire[:attachments].length).to eq(1)
      expect(wire[:attachments].first[:content_type]).to eq("image/jpeg")

      expect(WebPushNotifications).to have_received(:send_to_byte).with(
        hash_including(title: "🔔 Someone's at the door"),
      )
    end

    it "still pushes something when the picture arrives with no caption" do
      post :byte_photo, params: { files: [snapshot] }

      expect(ByteMessage.order(:id).last.body).to eq("")
      expect(WebPushNotifications).to have_received(:send_to_byte).with(hash_including(title: be_present))
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

      # Stamping the key as used is what makes a stale one visible on the keys page.
      it "accepts a valid key, posting into that key's own Buddy thread and stamping it used" do
        authenticate(api_key.key)

        expect {
          post :byte_photo, params: { files: [snapshot], body: "🔔 Someone's at the door" }
        }.to change { api_key.reload.last_used_at }.from(nil)

        expect(response).to have_http_status(:created)
        message = ByteMessage.order(:id).last
        expect(message.byte_conversation).to eq(buddy_convo)
        expect(message.files.attachments.size).to eq(1)
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

      it "refuses a key nobody issued, or one that's been disabled" do
        api_key.update!(enabled: false)

        ["NOT-A-REAL-KEY", api_key.key].each do |key|
          authenticate(key)

          expect { post :byte_photo, params: { files: [snapshot] } }.not_to change(ByteMessage, :count)
          expect(response).to have_http_status(:unauthorized)
        end
      end

      # This controller skips CSRF verification. If a session cookie were enough
      # here, any page they happened to be looking at could post into the thread.
      it "refuses a signed-in session with no Authorization header" do
        sign_in user

        expect { post :byte_photo, params: { files: [snapshot] } }.not_to change(ByteMessage, :count)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "refuses a request carrying no image, or a file that isn't one, rather than posting an empty bubble" do
      [{ body: "🔔 Someone's at the door" }, { files: [snapshot(type: "application/pdf", name: "doc.pdf")] }].each do |params|
        expect { post :byte_photo, params: params }.not_to change(ByteMessage, :count)
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    it "refuses an oversized image" do
      stub_const("ByteMessage::MAX_UPLOAD_BYTES", 1)

      expect {
        post :byte_photo, params: { files: [snapshot(bytes: "several-bytes")] }
      }.not_to change(ByteMessage, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  # A doorbell RING also reaches Chelsea — as one SHARED row rather than a
  # second copy, so both people are looking at the same frame and a reaction on
  # it is one reaction (ByteMessageShare).
  #
  # She's a literal id in the controller (there's no partner relation on User to
  # derive her from), so the spec stubs it rather than seeding that id.
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

    # It goes to HER, not to everyone under the roof, and the frame stays in the
    # thread it was posted to.
    it "shares the same frame with her alone, pushed and broadcast to her own thread", :aggregate_failures do
      expect(ByteNotifier).to receive(:notify).with(chelsea, anything)

      expect { ring }.to change(ByteMessage, :count).by(1).and change(ByteMessageShare, :count).by(1)

      message = ByteMessage.order(:id).last
      expect(message.byte_conversation).to eq(buddy_convo)
      expect(hers.visible_messages).to include(message)
      expect(hers.byte_messages).to be_empty
      expect(theirs.visible_messages).to be_empty
      expect(MonitorChannel).to have_received(:broadcast_to).with(
        chelsea, hash_including(data: hash_including(message: hash_including(conversation_id: hers.id)))
      )
    end

    # The frame shape's own word for a ring: a payload carrying only that, with
    # no `rang` and no `type`, is still a ring.
    it "shares a ring the shape only labelled as a doorbell event" do
      expect {
        post :byte_photo, params: {
          files:    [snapshot],
          metadata: { camera: "camera.doorbell_fluent", location: "doorbell", event: "doorbell" }.to_json,
        }
      }.to change(ByteMessageShare, :count).by(1)
    end

    # The same camera reports a person merely SEEN — no ring — and waking
    # someone for a person walking past the door is the wrong ping.
    it "does not share a person only seen, a frame from another camera, or a photo with no metadata" do
      doorbell = { camera: "camera.doorbell_fluent", location: "doorbell" }
      [
        -> { post :byte_photo, params: { files: [snapshot], body: "Someone out front", metadata: doorbell.merge(subject: "person", detected: true).to_json } },
        -> { post :byte_photo, params: { files: [snapshot], metadata: doorbell.merge(event: "person").to_json } },
        -> { ring(location: "driveway") },
        -> { post :byte_photo, params: { files: [snapshot] } },
      ].each do |attempt|
        expect { attempt.call }.not_to change(ByteMessageShare, :count)
      end
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
  end
end
