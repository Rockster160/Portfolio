require "rails_helper"

RSpec.describe ByteController, type: :controller do
  let(:rocco) { User.me }

  before { allow(ByteLocal).to receive(:deliver).and_return(nil) }

  describe "GET #show" do
    render_views

    it "renders the chat surface for the owner" do
      sign_in rocco

      get :show

      expect(response).to be_successful
      expect(response.body).to include("byte-app")
      expect(response.body).to include("byte-composer")
    end

    it "forbids everyone else" do
      sign_in create(:user)

      get :show

      expect(response).to have_http_status(:forbidden)
    end

    it "lets Chelsea in, scoped to a Buddy conversation" do
      chelsea = create(:user, id: 58_128)
      sign_in chelsea

      get :show

      expect(response).to be_successful
      expect(chelsea.byte_conversations.reload.map(&:mode)).to all(eq("buddy"))
    end

    # The page used to brand itself off the USER's default pet, so opening a
    # Suki thread on Rocco's account said "Byte" in the tab, the home-screen
    # title, the header avatar, and the composer placeholder.
    it "wears the open thread's pet, not the account's default one" do
      sign_in rocco
      # #show opens the most recently active thread, so this is the one it lands on.
      convo = rocco.byte_conversations.create!(name: "with suki", mode: :buddy)
      convo.update!(buddy_theme: :suki, last_message_at: Time.current)

      get :show

      expect(response.body).to include('data-buddy-name="Suki"')
      expect(response.body).to include('content="Suki"')      # PWA home-screen title
      expect(response.body).to include("/suki.webmanifest")
      expect(response.body).to include("Say something to Suki")
      expect(response.body).not_to include("Say something to Byte")
    end

    # Everything above is baked in for the thread that happened to be open. A
    # switch has to repaint it, which needs the pets the client has no thread
    # for - so the whole table ships once, and the images that follow the switch
    # are marked for it to find.
    it "ships every pet's chrome so a switch can repaint without a round trip" do
      sign_in rocco

      get :show

      expect(response.body).to include("data-buddy-themes=")
      expect(response.body.scan("data-byte-pet-avatar").length).to be >= 2
    end

    # #show renders the most recently ACTIVE thread; the client opens the last
    # VIEWED one from localStorage, and those differ whenever another thread got
    # a message after you left yours. Repainting for that needs to know which
    # pet a claude or bash thread wears, and the answer isn't the Suki one that
    # happened to be baked into the page.
    it "names the account's own pet for threads that have none of their own" do
      sign_in rocco
      suki = rocco.byte_conversations.create!(name: "with suki", mode: :buddy)
      suki.update!(buddy_theme: :suki, last_message_at: Time.current)

      get :show

      expect(response.body).to include('data-buddy-theme="suki"')
      expect(response.body).to include('data-default-buddy-theme="byte"')
    end

    # Without this, #show opens whichever thread has the newest message - which
    # is a different one any time a watch fired somewhere else while you were
    # reading - and the client then had to correct it after boot. Reloading a
    # Byte thread painted Suki's face, name and favicon over it.
    describe "with a thread named in the URL" do
      let!(:byte_thread) {
        rocco.byte_conversations.create!(name: "mine", mode: :buddy).tap { |c|
          c.update!(buddy_theme: :byte, last_message_at: 1.hour.ago)
        }
      }
      let!(:suki_thread) {
        rocco.byte_conversations.create!(name: "with suki", mode: :buddy).tap { |c|
          c.update!(buddy_theme: :suki, last_message_at: Time.current)
        }
      }

      before { sign_in rocco }

      # What the client boots from, so this is the thread that actually opens.
      def opened_id
        response.body[/data-initial-conversation-id="(\d+)"/, 1].to_i
      end

      it "opens it instead of the most recently active one" do
        get :show, params: { conversation_id: byte_thread.id }

        expect(opened_id).to eq(byte_thread.id)
        expect(response.body).to include('data-buddy-name="Byte"')
      end

      it "still falls back to most-recent when no thread is named" do
        get :show

        expect(opened_id).to eq(suki_thread.id)
      end

      it "ignores someone else's thread" do
        theirs = create(:user).byte_conversations.create!(name: "theirs", mode: :buddy)

        get :show, params: { conversation_id: theirs.id }

        expect(opened_id).to eq(suki_thread.id)
      end

      it "ignores an archived one, which isn't in the list to switch back to" do
        byte_thread.update!(archived: true)

        get :show, params: { conversation_id: byte_thread.id }

        expect(opened_id).to eq(suki_thread.id)
      end

      it "ignores a garbage id rather than blowing up" do
        get :show, params: { conversation_id: "nonsense" }

        expect(response).to be_successful
        expect(opened_id).to eq(suki_thread.id)
      end

      # Buddy-only members never see claude threads in their list, so a link to
      # one must not become a back door into rendering it.
      it "ignores a thread the viewer isn't allowed to see" do
        chelsea = create(:user, id: 58_128)
        claude  = chelsea.byte_conversations.create!(name: "shell", mode: :claude)
        sign_in chelsea

        get :show, params: { conversation_id: claude.id }

        expect(opened_id).not_to eq(claude.id)
        expect(chelsea.byte_conversations.find(opened_id).mode).to eq("buddy")
      end
    end
  end

  describe "DELETE #delete_message" do
    before { sign_in rocco }

    let(:convo) { rocco.byte_conversations.create!(name: :Buddy, mode: :buddy) }

    it "cancels a queued message" do
      msg = convo.byte_messages.create!(user: rocco, direction: :outbound, body: "held", state: :queued)

      expect {
        delete :delete_message, params: { id: msg.id }
      }.to change { ByteMessage.exists?(msg.id) }.from(true).to(false)

      expect(response).to have_http_status(:no_content)
    end

    it "refuses to cancel a message that already dispatched" do
      msg = convo.byte_messages.create!(user: rocco, direction: :outbound, body: "sent", state: :sent)

      delete :delete_message, params: { id: msg.id }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(ByteMessage.exists?(msg.id)).to be(true)
    end

    it "won't touch another user's message" do
      other = create(:user)
      convo2 = other.byte_conversations.create!(name: :Buddy, mode: :buddy)
      msg = convo2.byte_messages.create!(user: other, direction: :outbound, body: "held", state: :queued)

      delete :delete_message, params: { id: msg.id }

      expect(response).to have_http_status(:not_found)
      expect(ByteMessage.exists?(msg.id)).to be(true)
    end
  end

  describe "Chelsea is buddy-only" do
    let(:chelsea) { create(:user, id: 58_128) }

    before { sign_in chelsea }

    it "forces new conversations to buddy mode regardless of params" do
      post :create_conversation, params: { name: "shell", mode: "bash" }

      expect(chelsea.byte_conversations.order(:id).last.mode).to eq("buddy")
    end

    it "refuses /mode switches" do
      convo = chelsea.byte_conversations.create!(name: :Buddy, mode: :buddy)

      post :create_message, params: { conversation_id: convo.id, body: "/mode bash" }

      expect(convo.reload.mode).to eq("buddy")
    end

    it "never dispatches a non-buddy conversation to the Mac" do
      convo = chelsea.byte_conversations.create!(name: :Legacy, mode: :claude)
      expect(ByteLocal).not_to receive(:deliver)

      post :create_message, params: { conversation_id: convo.id, body: "hi" }
    end
  end

  describe "/buddy theme switch" do
    before { sign_in rocco }

    def buddy_convo
      rocco.byte_conversations.create!(name: :Buddy, mode: :buddy, buddy_theme: "byte")
    end

    it "swaps the pet theme on the thread and does not dispatch to the Mac" do
      convo = buddy_convo
      expect(ByteLocal).not_to receive(:deliver)

      post :create_message, params: { conversation_id: convo.id, body: "/buddy suki" }

      expect(convo.reload.buddy_theme).to eq("suki")
    end

    it "resets the stored expression so the new pet never renders a face it lacks" do
      convo = rocco.byte_conversations.create!(name: :Buddy, mode: :buddy, buddy_theme: "moss", buddy_expression: "wink")

      post :create_message, params: { conversation_id: convo.id, body: "/buddy suki" }

      expect(convo.reload.buddy_expression).to eq("neutral")
    end

    it "acks with the new pet name instead of a bubble-less send" do
      convo = buddy_convo

      post :create_message, params: { conversation_id: convo.id, body: "/buddy moss" }

      ack = convo.byte_messages.order(:id).last
      expect(ack.body).to include("Moss")
      expect(ack.metadata["source"]).to eq("slash")
    end

    it "rejects an unknown theme with a usage hint and leaves the theme alone" do
      convo = buddy_convo

      post :create_message, params: { conversation_id: convo.id, body: "/buddy dragon" }

      expect(convo.reload.buddy_theme).to eq("byte")
      expect(convo.byte_messages.order(:id).last.body).to include("usage:")
    end

    it "no-ops with a nudge when the thread is already that pet" do
      convo = buddy_convo

      post :create_message, params: { conversation_id: convo.id, body: "/buddy byte" }

      expect(convo.byte_messages.order(:id).last.body).to include("already")
    end

    it "refuses outside buddy mode" do
      convo = rocco.byte_conversations.create!(name: :Legacy, mode: :claude)

      post :create_message, params: { conversation_id: convo.id, body: "/buddy suki" }

      expect(convo.byte_messages.order(:id).last.body).to include("Buddy thing")
    end
  end

  describe "POST #create_message" do
    before { sign_in rocco }

    it "persists the outbound message and returns wire JSON" do
      expect {
        post :create_message, params: { body: "hello there" }
      }.to change { rocco.byte_messages.count }.by(1)

      expect(response).to have_http_status(:created)
      payload = JSON.parse(response.body)
      expect(payload).to include("body" => "hello there", "direction" => "outbound")
    end

    it "rejects empty bodies" do
      post :create_message, params: { body: "   " }
      expect(response).to have_http_status(:bad_request)
    end

    it "echoes the client-supplied local_id back through metadata" do
      post :create_message, params: { body: "queued send", local_id: "abc-123" }
      expect(response).to have_http_status(:created)
      payload = JSON.parse(response.body)
      expect(payload["metadata"]).to include("local_id" => "abc-123")
      expect(rocco.byte_messages.last.metadata["local_id"]).to eq("abc-123")
    end
  end

  describe "POST #create_message with attachments" do
    before { sign_in rocco }

    let(:convo) { rocco.byte_conversations.create!(name: :T, mode: :claude) }

    def signed_image(name: "photo.png")
      ActiveStorage::Blob.create_and_upload!(
        io:           StringIO.new("png-bytes"),
        filename:     name,
        content_type: "image/png",
      ).signed_id
    end

    it "attaches a pre-uploaded image to the outbound message" do
      sid = signed_image
      expect {
        post :create_message, params: { conversation_id: convo.id, body: "look", attachment_signed_ids: [sid] }
      }.to change { convo.byte_messages.outbound.count }.by(1)

      expect(response).to have_http_status(:created)
      msg = convo.byte_messages.outbound.last
      expect(msg.files.count).to eq(1)
      expect(msg.files.first.filename.to_s).to eq("photo.png")
      wire = JSON.parse(response.body)
      expect(wire["attachments"].size).to eq(1)
      expect(wire["attachments"].first).to include("content_type" => "image/png")
    end

    it "allows an image-only send with a blank body" do
      sid = signed_image
      post :create_message, params: { conversation_id: convo.id, body: "", attachment_signed_ids: [sid] }

      expect(response).to have_http_status(:created)
      expect(convo.byte_messages.outbound.last.files.count).to eq(1)
    end

    it "still 400s a blank send with no attachments" do
      post :create_message, params: { conversation_id: convo.id, body: "   " }
      expect(response).to have_http_status(:bad_request)
    end

    it "silently drops a tampered signed id instead of erroring the send" do
      post :create_message, params: { conversation_id: convo.id, body: "hi", attachment_signed_ids: ["not-a-real-signed-id"] }

      expect(response).to have_http_status(:created)
      expect(convo.byte_messages.outbound.last.files.count).to eq(0)
    end
  end

  describe "POST #uploads" do
    before { sign_in rocco }

    def image(type: "image/png", name: "chart.png", bytes: "pretend-png")
      Rack::Test::UploadedFile.new(StringIO.new(bytes), type, original_filename: name)
    end

    it "stores the image and returns a resolvable signed id" do
      post :uploads, params: { files: [image] }

      expect(response).to have_http_status(:created)
      att = JSON.parse(response.body)["attachments"].first
      expect(att["signed_id"]).to be_present
      expect(att).to include("content_type" => "image/png", "filename" => "chart.png")
      expect(ActiveStorage::Blob.find_signed(att["signed_id"])).to be_present
    end

    it "rejects a non-image file type" do
      post :uploads, params: { files: [image(type: "application/pdf", name: "doc.pdf")] }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/unsupported/i)
    end

    it "rejects an oversized image" do
      stub_const("ByteMessage::MAX_UPLOAD_BYTES", 1)

      post :uploads, params: { files: [image(bytes: "several-bytes")] }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/too large/i)
    end

    it "forbids a non-owner" do
      sign_in create(:user)
      post :uploads, params: { files: [image] }
      expect(response).to have_http_status(:forbidden)
    end

    it "transcodes a HEIC on the way in, since nothing downstream reads one" do
      png = ChunkyPNG::Image.new(4, 4, ChunkyPNG::Color::WHITE).to_blob
      post :uploads, params: {
        files: [Rack::Test::UploadedFile.new(StringIO.new(png), "image/heic", original_filename: "IMG_1.HEIC")],
      }

      expect(response).to have_http_status(:created)
      att = JSON.parse(response.body)["attachments"].first
      expect(att).to include("content_type" => "image/jpeg", "filename" => "IMG_1.jpg")
    end

    # A rejection partway through a batch used to leave the earlier files stored
    # with nothing to attach them to.
    it "stores nothing at all when one file in a batch is rejected" do
      expect {
        post :uploads, params: { files: [image, image(type: "application/pdf", name: "doc.pdf")] }
      }.not_to change(ActiveStorage::Blob, :count)

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "refuses a batch bigger than MAX_UPLOADS" do
      files = Array.new(ByteController::MAX_UPLOADS + 1) { image }

      expect { post :uploads, params: { files: files } }.not_to change(ActiveStorage::Blob, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to match(/too many/i)
    end
  end

  describe "GET #csrf" do
    it "returns a fresh token for the owner" do
      sign_in rocco
      get :csrf
      expect(response).to be_successful
      expect(JSON.parse(response.body).keys).to include("token")
    end

    it "forbids everyone else" do
      sign_in create(:user)
      get :csrf
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET #messages" do
    before { sign_in rocco }

    it "returns the recent history in chronological order with has_more/oldest_id" do
      old_msg = rocco.byte_messages.create!(body: "old", direction: :outbound, created_at: 1.hour.ago)
      new_msg = rocco.byte_messages.create!(body: "new", direction: :inbound)

      get :messages

      body = JSON.parse(response.body)
      ids = body.fetch("messages").map { |m| m["id"] }
      expect(ids).to eq([old_msg.id, new_msg.id])
      expect(body["has_more"]).to eq(false)
      expect(body["oldest_id"]).to eq(old_msg.id)
    end

    it "paginates older messages via ?before= with has_more transitioning to false" do
      first  = rocco.byte_messages.create!(body: "1", direction: :outbound, created_at: 3.hours.ago)
      second = rocco.byte_messages.create!(body: "2", direction: :outbound, created_at: 2.hours.ago)
      third  = rocco.byte_messages.create!(body: "3", direction: :outbound, created_at: 1.hour.ago)

      get :messages, params: { before: third.id, limit: 1 }
      body1 = JSON.parse(response.body)
      expect(body1["messages"].map { |m| m["id"] }).to eq([second.id])
      expect(body1["has_more"]).to eq(true)
      expect(body1["oldest_id"]).to eq(second.id)

      get :messages, params: { before: second.id, limit: 5 }
      body2 = JSON.parse(response.body)
      expect(body2["messages"].map { |m| m["id"] }).to eq([first.id])
      expect(body2["has_more"]).to eq(false)
    end

    it "caps `limit` at MAX_LIMIT" do
      15.times { |i| rocco.byte_messages.create!(body: "m#{i}", direction: :outbound) }
      # Ridiculous limit — should be silently capped, no error.
      get :messages, params: { limit: 100_000 }
      expect(response).to be_successful
      expect(JSON.parse(response.body)["messages"].size).to be <= ByteController::MAX_LIMIT
    end
  end
end
