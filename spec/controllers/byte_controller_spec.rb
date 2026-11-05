require "rails_helper"

RSpec.describe ByteController, type: :controller do
  describe "the controller" do
    let(:rocco) { User.me }

    before { allow(ByteLocal).to receive(:deliver).and_return(nil) }

    describe "GET #show" do
      render_views

      # Rendered inline: the saved text size paints on the first frame, both
      # managers are drawer rows that open a dialog, the name slots are marked so
      # a thread switch can repaint them, and every pet's chrome ships once so
      # the switch needs no round trip.
      it "renders the owner's chat surface, its drawer dialogs, every mode and every pet", :aggregate_failures do
        rocco.update!(byte_font_scale: 130)
        sign_in rocco

        get :show

        body = response.body
        expect(response).to be_successful
        expect(body).to include("byte-app", "byte-composer", 'data-kiosk="false"')
        expect(body).not_to include("byte-kiosk-pad")
        expect(body).to include("data-byte-open-routines", "data-byte-open-reminders")
        expect(body).to include("data-byte-routines-modal", "data-byte-reminders-modal")
        expect(body).to include("data-byte-open-settings", "data-byte-settings-modal", "data-byte-jil-search")
        expect(body).to include("--byte-font-scale: 1.3", "data-byte-font-bigger")
        expect(body.scan("data-buddy-name-slot").length).to be >= 4
        expect(body).to include("data-buddy-themes=")
        expect(body.scan("data-byte-pet-avatar").length).to be >= 2

        # Claude / Bash / Jarvis hand off to the owner's Mac, so only the owner is offered them.
        expect(body).to include('value="claude"', 'value="bash"', 'value="jarvis"', 'name="buddy_theme"')
        Buddy::Themes.keys.each { |theme| expect(body).to include(%(value="#{theme}")) }

        # Adopting is a way to START a Claude thread, and boards are reached from the drawer.
        expect(body).to include("data-byte-new-adopt", "data-byte-adopt-modal", %(href="/board"))
        expect(body).to include("data-byte-menu-buddy", "data-byte-buddy-modal")
        expect(body).not_to include("data-byte-menu-adopt", "data-byte-menu-board")
      end

      # A page visit is shown Byte's About page; anything else is a bare 403.
      it "turns everyone else away to the About page" do
        sign_in create(:user)

        get :show

        expect(response).to redirect_to(playground_project_path(PlaygroundProject.find(:byte)))
      end

      # Copy that names the companion names THIS thread's companion, and a
      # buddy-only member is offered no mode choice at all.
      it "lets Chelsea in, scoped to a Buddy conversation wearing her own pet" do
        chelsea = create(:user, id: 58_128)
        sign_in chelsea

        get :show

        expect(response).to be_successful
        expect(chelsea.byte_conversations.reload.map(&:mode)).to all(eq("buddy"))
        expect(response.body).to include("<span data-buddy-name-slot>Moss</span>")
        expect(response.body).not_to include('value="bash"', 'value="jarvis"')
        expect(response.body).to include('name="mode" value="buddy"')
        expect(response.body).not_to include("data-byte-new-adopt", "data-byte-adopt-modal")
        expect(response.body).to include("data-byte-menu-buddy")
      end

      # #show opens the most recently active thread, and wears that thread's
      # pet, not the account's default. The client may open a different one
      # from localStorage, so the account's own pet ships too.
      it "wears the open thread's pet, naming the account's own pet for threads with none" do
        sign_in rocco
        convo = rocco.byte_conversations.create!(name: "with suki", mode: :buddy)
        convo.update!(buddy_theme: :suki, last_message_at: Time.current)

        get :show

        expect(response.body).to include('data-buddy-name="Suki"')
        expect(response.body).to include('content="Suki"')      # PWA home-screen title
        expect(response.body).to include("/suki.webmanifest")
        expect(response.body).to include('data-buddy-theme="suki"', 'data-default-buddy-theme="byte"')
      end

      # Without this, #show opens whichever thread has the newest message, which
      # is a different one any time a watch fired somewhere else.
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

        it "falls back to most-recent when none, someone else's, an archived or a garbage one is named" do
          theirs = create(:user).byte_conversations.create!(name: "theirs", mode: :buddy)
          archived = rocco.byte_conversations.create!(name: "old", mode: :buddy, archived: true)

          [{}, { conversation_id: theirs.id }, { conversation_id: archived.id }, { conversation_id: "nonsense" }].each do |params|
            get :show, params: params

            expect(response).to be_successful
            expect(opened_id).to eq(suki_thread.id), params.to_s
          end
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

    # The wall tablet: the pet up top, the routines pinned to the Quick grid as
    # buttons underneath, and nothing else. Same page and same controller as the
    # chat - what differs is what's on screen and which thread it opens.
    describe "GET #kiosk" do
      render_views

      def routine!(name, position: nil, enabled: true, description: nil, monitor: nil)
        BuddyRoutine.create!(
          user:        rocco,
          name:        name,
          description: description,
          position:    position,
          enabled:     enabled,
          metadata:    monitor ? { "monitor" => monitor } : {},
          steps:       [BuddyRoutine.step(:message_partner, { to: "someone", message: "night" })],
        )
      end

      before { sign_in rocco }

      def button_names
        response.body.scan(/data-kiosk-routine="\d+"[^>]*>([^<]+)</).flatten.map(&:strip)
      end

      # Only starred, enabled routines, in the order they were dragged into; a
      # button shows only its name (the description is a hover title). A routine
      # with a monitor key gets a LIVE button kiosk.js subscribes to. The service
      # worker refuses to cache a page without the shell marker.
      it "renders the wall pad with the pinned routines as buttons", :aggregate_failures do
        routine!("Wind Down", position: 1)
        routine!("Prep Printer", position: 0, description: "Powers it on, waits, then preheats")
        routine!("Almost Never")
        routine!("Muted", position: 2, enabled: false)
        routine!("Yoga Lights", position: 3, monitor: "yoga-lights")

        get :kiosk

        body = response.body
        expect(response).to be_successful
        expect(body).to include('data-kiosk="true"', "byte-kiosk-pad", "data-kiosk-who")
        expect(body).to include('<meta name="byte-shell" content="ok">')
        expect(button_names).to eq(["Prep Printer", "Wind Down", "Yoga Lights"])
        expect(body).not_to include("byte-kiosk-btn-sub")
        expect(body).to include('title="Powers it on, waits, then preheats"')
        expect(body.scan("data-kiosk-monitor=").length).to eq(1)
        expect(body).to include('data-kiosk-monitor="yoga-lights"')
      end

      it "renders an empty pad when nothing is pinned" do
        routine!("Saved but unstarred")

        get :kiosk

        expect(response).to be_successful
        expect(button_names).to be_empty
      end

      # There's no keyboard on a wall, and a claude or bash thread is nothing but
      # typing. #show opens whichever thread spoke most recently, which here would
      # have landed the tablet on a shell.
      it "opens a Buddy thread even when a claude one is newer" do
        buddy = rocco.byte_conversations.create!(name: "wall", mode: :buddy, last_message_at: 1.hour.ago)
        rocco.byte_conversations.create!(name: "shell", mode: :claude, last_message_at: Time.current)

        get :kiosk

        expect(response.body).to include(%(data-initial-conversation-id="#{buddy.id}"))
        expect(response.body).to include('data-active-mode="buddy"')
      end

      it "makes one when there's no Buddy thread to open" do
        rocco.byte_conversations.destroy_all

        expect { get :kiosk }.to change { rocco.byte_conversations.buddy.count }.by(1)
        expect(response).to be_successful
      end

      it "honours a thread named in the URL" do
        wanted = rocco.byte_conversations.create!(name: "kitchen", mode: :buddy, last_message_at: 1.hour.ago)
        rocco.byte_conversations.create!(name: "other", mode: :buddy, last_message_at: Time.current)

        get :kiosk, params: { conversation_id: wanted.id }

        expect(response.body).to include(%(data-initial-conversation-id="#{wanted.id}"))
      end

      # Which companion is on the wall IS which thread it's pinned to.
      describe "the thread it's been set to" do
        let!(:suki) {
          rocco.byte_conversations.create!(name: "kitchen", mode: :buddy).tap { |c|
            c.update!(buddy_theme: :suki, last_message_at: 2.hours.ago)
          }
        }
        let!(:newest) {
          rocco.byte_conversations.create!(name: "phone", mode: :buddy).tap { |c|
            c.update!(buddy_theme: :byte, last_message_at: Time.current)
          }
        }

        it "opens it, and wears its companion, over the one that spoke last" do
          ByteConversation.pin_kiosk!(suki)

          get :kiosk

          expect(response.body).to include(%(data-initial-conversation-id="#{suki.id}"))
          expect(response.body).to include('data-buddy-name="Suki"')
        end

        it "falls back to the newest when nothing is pinned, or the pinned one is archived" do
          get :kiosk
          expect(response.body).to include(%(data-initial-conversation-id="#{newest.id}"))

          ByteConversation.pin_kiosk!(suki)
          suki.update!(archived: true)
          get :kiosk
          expect(response.body).to include(%(data-initial-conversation-id="#{newest.id}"))
        end

        it "still lets the URL override it" do
          ByteConversation.pin_kiosk!(suki)

          get :kiosk, params: { conversation_id: newest.id }

          expect(response.body).to include(%(data-initial-conversation-id="#{newest.id}"))
        end
      end

      # An icon added from this page has to reopen the KIOSK. Both manifests are
      # the same pet, and start_url is the only thing separating them.
      it "points at the pet's kiosk manifest so an install comes back here" do
        convo = rocco.byte_conversations.create!(name: "wall", mode: :buddy)
        convo.update!(buddy_theme: :suki, last_message_at: Time.current)

        get :kiosk

        expect(response.body).to include("/suki_kiosk.webmanifest")
        expect(response.body).not_to include(%(href="/suki.webmanifest"))
        expect(response.body).to include('content="Suki Kiosk"')
      end

      it "forbids anyone who can't open Byte at all, and lets Chelsea put one on a wall" do
        sign_in create(:user)
        get :kiosk
        expect(response).to have_http_status(:forbidden)

        sign_in create(:user, id: 58_128)
        get :kiosk
        expect(response).to be_successful
      end
    end

    describe "POST #pin_kiosk_conversation" do
      before { sign_in rocco }

      def buddy!(name)
        rocco.byte_conversations.create!(name: name, mode: :buddy)
      end

      # "Which one is out there" is a single fact, so pinning unpins the last.
      it "points the wall at the chosen thread, unpinning whichever was there before" do
        first  = buddy!("kitchen")
        second = buddy!("desk")
        ByteConversation.pin_kiosk!(first)

        post :pin_kiosk_conversation, params: { conversation_id: second.id }

        expect(response).to be_successful
        expect(rocco.byte_conversations.kiosk.pluck(:id)).to eq([second.id])
      end

      # The kiosk can't show a claude thread.
      it "refuses a claude thread or someone else's" do
        claude = rocco.byte_conversations.create!(name: "shell", mode: :claude)
        theirs = create(:user).byte_conversations.create!(name: "theirs", mode: :buddy)

        [claude, theirs].each do |convo|
          post :pin_kiosk_conversation, params: { conversation_id: convo.id }

          expect(response).to have_http_status(:not_found)
          expect(convo.reload).not_to be_kiosk
        end
      end
    end

    describe "POST #pin_primary_conversation" do
      # Conversation ids, in the order they were pushed to the client.
      let(:broadcasts) { [] }

      before do
        sign_in rocco
        allow(MonitorChannel).to receive(:broadcast_to) { |_user, payload|
          broadcasts << payload.dig(:data, :conversation)&.dig(:id)
        }
      end

      def buddy!(name)
        rocco.byte_conversations.create!(name: name, mode: :buddy)
      end

      # Both rows have to repaint on a second device, or the one that lost it
      # keeps showing the marker.
      it "points everything self-initiated at the chosen thread, broadcasting loser and winner", :aggregate_failures do
        first  = buddy!("Byte")
        second = buddy!("Moss")
        ByteConversation.pin_primary!(first)

        post :pin_primary_conversation, params: { conversation_id: second.id }

        expect(response).to be_successful
        expect(rocco.byte_conversations.primary.pluck(:id)).to eq([second.id])
        expect(ByteConversation.for_self_initiated(rocco)).to eq(second)
        expect(broadcasts).to include(first.id, second.id)
      end

      # A row predating the claim-on-create callback: nothing carries the flag, so
      # there is no row to repaint and the resolved id rides along on the new
      # one's own broadcast.
      it "doesn't broadcast a default holder that was never marked" do
        first  = buddy!("Byte")
        second = buddy!("Moss")
        rocco.byte_conversations.update_all(primary_at: nil)

        post :pin_primary_conversation, params: { conversation_id: second.id }

        expect(broadcasts).to eq([second.id])
        expect(first.reload.primary_at).to be_nil
      end

      # Nothing self-initiated is ever sent to a claude or bash thread, so aiming
      # at one would point briefings at somewhere they can't arrive.
      it "refuses a claude thread" do
        claude = rocco.byte_conversations.create!(name: "shell", mode: :claude)

        post :pin_primary_conversation, params: { conversation_id: claude.id }

        expect(response).to have_http_status(:not_found)
        expect(claude.reload).not_to be_primary
      end

      # Their own first thread claims primary on creation, so the thing to assert
      # is that OUR request changed nothing — not that the flag is absent.
      it "refuses someone else's" do
        theirs = create(:user).byte_conversations.create!(name: "theirs", mode: :buddy)
        was    = theirs.reload.primary_at

        post :pin_primary_conversation, params: { conversation_id: theirs.id }

        expect(response).to have_http_status(:not_found)
        expect(theirs.reload.primary_at).to eq(was)
        expect(rocco.byte_conversations.primary).to be_empty
      end

      it "reports the default, then the chosen one, on the conversations index" do
        first = buddy!("Byte")
        second = buddy!("Moss")

        get :list_conversations
        expect(response.parsed_body["primary_id"]).to eq(first.id)

        ByteConversation.pin_primary!(second)
        get :list_conversations
        expect(response.parsed_body["primary_id"]).to eq(second.id)
      end
    end

    describe "GET #claude_sessions" do
      it "lists the owner's sessions and nobody else's" do
        convo = rocco.byte_conversations.create!(mode: :claude)
        allow(ByteLocal).to receive(:list_claude_sessions).and_return([{ id: "abc" }])

        sign_in rocco
        get :claude_sessions, params: { conversation_id: convo.id }
        expect(JSON.parse(response.body)["sessions"]).to eq([{ "id" => "abc" }])

        chelsea = create(:user, id: 58_128)
        theirs = chelsea.byte_conversations.create!(mode: :buddy)
        sign_in chelsea
        get :claude_sessions, params: { conversation_id: theirs.id }
        expect(response).to have_http_status(:not_found)
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

      it "refuses /mode switches and never dispatches a non-buddy conversation to the Mac" do
        convo = chelsea.byte_conversations.create!(name: :Buddy, mode: :buddy)
        legacy = chelsea.byte_conversations.create!(name: :Legacy, mode: :claude)
        expect(ByteLocal).not_to receive(:deliver)

        post :create_message, params: { conversation_id: convo.id, body: "/mode bash" }
        post :create_message, params: { conversation_id: legacy.id, body: "hi" }

        expect(convo.reload.mode).to eq("buddy")
      end
    end

    describe "/buddy theme switch" do
      before { sign_in rocco }

      def buddy_convo
        rocco.byte_conversations.create!(name: :Buddy, mode: :buddy, buddy_theme: "byte")
      end

      # Resetting the expression means the new pet never renders a face it lacks.
      it "swaps the pet theme, resets the expression and acks as a slash reply, without the Mac" do
        convo = rocco.byte_conversations.create!(name: :Buddy, mode: :buddy, buddy_theme: "moss", buddy_expression: "wink")
        expect(ByteLocal).not_to receive(:deliver)

        post :create_message, params: { conversation_id: convo.id, body: "/buddy suki" }

        expect(convo.reload.buddy_theme).to eq("suki")
        expect(convo.buddy_expression).to eq("neutral")
        ack = convo.byte_messages.order(:id).last
        expect(ack.body).to include("Suki")
        expect(ack.metadata["source"]).to eq("slash")
      end

      it "leaves the theme alone but answers for an unknown theme, the same pet, or a non-buddy thread" do
        convo = buddy_convo
        claude = rocco.byte_conversations.create!(name: :Legacy, mode: :claude)

        [[convo, "/buddy dragon"], [convo, "/buddy byte"], [claude, "/buddy suki"]].each do |thread, cmd|
          expect {
            post :create_message, params: { conversation_id: thread.id, body: cmd }
          }.to change { thread.byte_messages.inbound.count }.by(1)
          expect(thread.reload.buddy_theme).to eq("byte"), cmd
        end
      end
    end

    # The wall picker (a kiosk or a board) sets which companion wears the thread
    # through a plain conversation PATCH, not the slash command — so a board's
    # chosen pet survives being reopened.
    describe "PATCH #update_conversation buddy_theme" do
      before { sign_in rocco }

      it "re-themes a buddy thread, resetting its expression, and ignores an unknown theme" do
        convo = rocco.byte_conversations.create!(mode: :buddy, buddy_theme: "byte", buddy_expression: "wink")

        patch :update_conversation, params: { id: convo.id, buddy_theme: "moss" }
        expect(response).to have_http_status(:ok)
        expect(convo.reload.buddy_theme).to eq("moss")
        expect(convo.buddy_expression).to eq("neutral")

        patch :update_conversation, params: { id: convo.id, buddy_theme: "dragon" }
        expect(convo.reload.buddy_theme).to eq("moss")
      end
    end

    describe "POST #create_message" do
      before { sign_in rocco }

      it "persists the outbound message and returns wire JSON, echoing the client's local_id" do
        expect {
          post :create_message, params: { body: "hello there", local_id: "abc-123" }
        }.to change { rocco.byte_messages.outbound.count }.by(1)

        expect(response).to have_http_status(:created)
        payload = JSON.parse(response.body)
        expect(payload).to include("body" => "hello there", "direction" => "outbound")
        expect(payload["metadata"]).to include("local_id" => "abc-123")
        expect(rocco.byte_messages.outbound.last.metadata["local_id"]).to eq("abc-123")
      end

      it "rejects empty bodies" do
        post :create_message, params: { body: "   " }
        expect(response).to have_http_status(:bad_request)
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
      end

      it "rejects an oversized image" do
        stub_const("ByteMessage::MAX_UPLOAD_BYTES", 1)

        post :uploads, params: { files: [image(bytes: "several-bytes")] }

        expect(response).to have_http_status(:unprocessable_entity)
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

      it "refuses a batch bigger than MAX_FILES" do
        files = Array.new(ByteImageIntake::MAX_FILES + 1) { image }

        expect { post :uploads, params: { files: files } }.not_to change(ActiveStorage::Blob, :count)
        expect(response).to have_http_status(:unprocessable_entity)
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

      # A trigger seed is a real row in the thread, persisted so the reply Buddy
      # sends has something to hang on, but never a bubble in the history.
      it "leaves the hidden trigger seeds out of the history" do
        said = rocco.byte_messages.create!(body: "mine", direction: :outbound, created_at: 2.hours.ago)
        seed = rocco.byte_messages.create!(
          body:       "[nothing was said to you - this fired on its own]",
          direction:  :outbound,
          created_at: 1.hour.ago,
          metadata:   { kind: :buddy_trigger, hidden: true },
        )

        get :messages

        ids = JSON.parse(response.body).fetch("messages").map { |m| m["id"] }
        expect(ids).to eq([said.id])
        expect(ids).not_to include(seed.id)
      end

      # `has_more` and `oldest_id` are answered from the same relation the page
      # comes out of, so a thread whose only older rows are seeds has to report
      # nothing older - otherwise the spinner promises a page that paints nothing.
      it "does not count them as older history still to come" do
        rocco.byte_messages.create!(
          body:       "seed",
          direction:  :outbound,
          created_at: 3.hours.ago,
          metadata:   { hidden: true },
        )
        shown = rocco.byte_messages.create!(body: "shown", direction: :outbound, created_at: 1.hour.ago)

        get :messages, params: { limit: 5 }

        body = JSON.parse(response.body)
        expect(body["messages"].map { |m| m["id"] }).to eq([shown.id])
        expect(body["has_more"]).to eq(false)
        expect(body["oldest_id"]).to eq(shown.id)
      end

      it "caps `limit` at MAX_LIMIT" do
        15.times { |i| rocco.byte_messages.create!(body: "m#{i}", direction: :outbound) }
        # Ridiculous limit — should be silently capped, no error.
        get :messages, params: { limit: 100_000 }
        expect(response).to be_successful
        expect(JSON.parse(response.body)["messages"].size).to be <= ByteController::MAX_LIMIT
      end
    end

    describe "POST #create_conversation" do
      it "wears the companion picked, ignoring a fake one and leaving non-Buddy threads unthemed" do
        sign_in rocco

        [[{ mode: "buddy", buddy_theme: "suki" }, "buddy", "suki"],
         [{ mode: "buddy", buddy_theme: "gremlin" }, "buddy", "byte"],
         [{ mode: "bash", buddy_theme: "suki" }, "bash", "byte"]].each do |params, mode, theme|
          post :create_conversation, params: params

          convo = rocco.byte_conversations.order(:id).last
          expect([convo.mode, convo.buddy_theme]).to eq([mode, theme]), params.to_s
        end
      end

      # "byte" is the column default, so choosing it on a non-Byte account looks
      # identical to choosing nothing to dirty-tracking. A buddy-only member is
      # pinned to Buddy whatever they post.
      it "falls back to the account's own pet, honours Byte on a non-Byte account, and pins Chelsea to Buddy" do
        chelsea = create(:user, id: 58_128)
        sign_in chelsea

        [[{ mode: "buddy" }, "buddy", "moss"],
         [{ mode: "buddy", buddy_theme: "byte" }, "buddy", "byte"],
         [{ mode: "bash" }, "buddy", nil]].each do |params, mode, theme|
          post :create_conversation, params: params

          convo = chelsea.byte_conversations.order(:id).last
          expect(convo.mode).to eq(mode), params.to_s
          expect(convo.buddy_theme).to eq(theme) if theme
        end
      end
    end

    describe "POST #font_scale" do
      it "saves it, clamping an absurd value, and hands back what it settled on" do
        sign_in rocco

        post :font_scale, params: { scale: 140 }
        expect(response.parsed_body["scale"]).to eq(140)
        expect(rocco.reload.byte_font_scale).to eq(140)

        post :font_scale, params: { scale: 9000 }
        expect(rocco.reload.byte_font_scale).to eq(User::FONT_SCALE_RANGE.max)
      end

      it "refuses someone who can't open Byte" do
        sign_in create(:user)

        post :font_scale, params: { scale: 140 }

        expect(response).to have_http_status(:forbidden)
      end
    end
  end

  describe "reacting to a message" do
    let(:user)  { User.me }
    let(:other) { create(:user) }
    let(:convo) { user.byte_conversations.create!(name: "t", mode: :buddy) }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(WebPushNotifications).to receive(:send_to_byte)
      sign_in user
    end

    def relay_message(owner: user, conversation: convo)
      conversation.byte_messages.create!(
        user:         owner,
        direction:    :inbound,
        state:        :delivered,
        body:         "dinner's ready",
        metadata:     { "kind" => "buddy_relay", "source" => "relay" },
        delivered_at: Time.current,
      )
    end

    describe "POST #react_message" do
      it "records the reaction and hands back the list" do
        message = relay_message

        post :react_message, params: { id: message.id, emoji: "👍" }

        expect(response).to be_successful
        reactions = response.parsed_body["reactions"]
        expect(reactions.pluck("emoji")).to eq(["👍"])
        expect(reactions.first["user_id"]).to eq(user.id)
      end

      it "takes it back off on a second tap" do
        message = relay_message
        post :react_message, params: { id: message.id, emoji: "👍" }

        post :react_message, params: { id: message.id, emoji: "👍" }

        expect(response.parsed_body["reactions"]).to be_empty
      end

      # Any icon the picker can offer, not a fixed six. The row is most-recently
      # used, so reacting reorders it.
      it "takes anything the picker could have handed back, reordering the picker row" do
        message = relay_message

        post :react_message, params: { id: message.id, emoji: "🍕" }

        expect(response).to be_successful
        expect(Buddy::Reactions.of(message.reload).pluck("emoji")).to eq(["🍕"])
        recents = response.parsed_body["recents"]
        expect(recents.first).to eq("🍕")
        expect(recents.length).to eq(Buddy::Reactions::RECENT_LIMIT)
      end

      it "refuses free text the picker could never produce" do
        message = relay_message

        post :react_message, params: { id: message.id, emoji: "lol nice one" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(Buddy::Reactions.of(message.reload)).to be_empty
      end

      # Anything in your own thread, not just what came from another person.
      it "takes one on something Buddy said" do
        message = convo.byte_messages.create!(
          user: user, direction: :inbound, state: :delivered,
          body: "all set", metadata: { "kind" => "buddy_reply" }, delivered_at: Time.current
        )

        post :react_message, params: { id: message.id, emoji: "👍" }

        expect(response).to be_successful
        expect(Buddy::Reactions.of(message.reload).pluck("emoji")).to eq(["👍"])
      end

      # Owning the message is the whole gate. Reaching into someone else's thread
      # is not how a reaction crosses over — the relay's two copies are.
      it "refuses someone else's message" do
        theirs = relay_message(
          owner: other, conversation: other.byte_conversations.create!(mode: :buddy),
        )

        post :react_message, params: { id: theirs.id, emoji: "👍" }

        expect(response).to have_http_status(:not_found)
        expect(Buddy::Reactions.of(theirs.reload)).to be_empty
      end
    end
  end

  # Reporting a bad reply from the message's own long-press menu. The line lands
  # on the Todo list as `#{id} [{body}] {description}`, which is the format asked
  # for and also, not coincidentally, one that survives ListItem.add.
  describe "replying to a message" do
    let(:user)  { User.me }
    let(:convo) { user.byte_conversations.create!(name: "t", mode: :buddy) }

    # The suite runs Sidekiq inline, so a dispatched turn would make a real call.
    around { |example| Sidekiq::Testing.fake! { example.run } }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      sign_in user
    end

    def said
      convo.byte_messages.create!(
        user:      user,
        direction: :inbound,
        state:     :delivered,
        body:      "Which calendar - Ours or Work?",
        metadata:  { "kind" => "buddy" },
      )
    end

    # The client sends the whole descriptor so its optimistic bubble can draw
    # the quote before any echo exists. Only the id is read off it; what gets
    # stored is the block the server builds for itself.
    it "reads the target off the metadata the offline queue carries" do
      target = said

      post :create_message, params: {
        conversation_id: convo.id,
        body:            "the second one",
        metadata:        { reply_to: { id: target.id, author: "whatever they like", excerpt: "..." } },
      }

      quote = convo.byte_messages.order(:id).last.metadata["reply_to"]
      expect(quote).to include("id" => target.id, "excerpt" => "Which calendar - Ours or Work?")
      expect(quote["author"]).not_to eq("whatever they like")
    end

    it "takes a bare id too" do
      target = said

      post :create_message, params: { conversation_id: convo.id, body: "the second one", reply_to: target.id }

      expect(convo.byte_messages.order(:id).last.metadata.dig("reply_to", "id")).to eq(target.id)
    end

    it "stores nothing when they replied to nothing" do
      post :create_message, params: { conversation_id: convo.id, body: "morning" }

      expect(convo.byte_messages.order(:id).last.metadata).not_to have_key("reply_to")
    end
  end

  describe "reporting a message" do
    let(:rocco) { User.me }
    let(:convo) { rocco.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current) }

    # jarvis_spec.rb builds a "TODO" list in a before(:context), which never rolls
    # back and so is visible to the whole suite run. Clear the field first so this
    # file owns the only match and isn't asserting against a leaked one.
    let!(:todo) {
      rocco.lists.ilike(name: "Todo").destroy_all
      List.create!(name: "Todo").tap { |l| UserList.create!(user: rocco, list: l, is_owner: true) }
    }

    def message(body)
      convo.byte_messages.create!(user: rocco, direction: :inbound, state: :delivered, body: body)
    end

    def items = todo.reload.list_items.map(&:name)

    before do
      allow(ByteLocal).to receive(:deliver).and_return(nil)
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(ActionCable.server).to receive(:broadcast)
      sign_in rocco
    end

    describe "POST #report_message" do
      it "files the id, the body and the description onto Todo" do
        msg = message("The plunge is at 4:45 AM.")

        post :report_message, params: { id: msg.id, description: "wrong timezone again" }

        expect(response).to be_successful
        expect(response.parsed_body["list"]).to eq("Todo")
        expect(items).to include("##{msg.id} [The plunge is at 4:45 AM.] wrong timezone again")
      end

      it "files without a description when the person left the box empty" do
        msg = message("Nope.")

        post :report_message, params: { id: msg.id, description: "" }

        expect(items).to include("##{msg.id} [Nope.]")
      end

      # The id has to lead. ListItem.add pulls a leading `[Section]` off the name
      # and files the row under it, so a line that opened with the quoted body
      # would have the body silently removed from what you see.
      it "keeps the quoted body out of the section-prefix position" do
        msg = message("Deploy finished successfully.")

        post :report_message, params: { id: msg.id, description: "it failed" }

        line = items.find { |n| n.include?("Deploy finished") }
        expect(line).to start_with("##{msg.id} [")
        expect(line).to include("Deploy finished successfully.")
      end

      it "truncates a long body but keeps the description whole" do
        msg = message("word " * 60)

        post :report_message, params: { id: msg.id, description: "rambling" }

        line = items.last
        expect(line).to end_with("rambling")
        expect(line).to include("...")
        expect(line.length).to be < 160
      end

      # A multi-line reply is the common case for a bad Buddy answer, and a list
      # item is one line.
      it "flattens newlines" do
        msg = message("Here you go:\n\n- one\n- two")

        post :report_message, params: { id: msg.id, description: "" }

        expect(items.last).to eq("##{msg.id} [Here you go: - one - two]")
      end

      # The body comes off the record, never off the client. The bubble's
      # data-full-body is editable by anything on the page.
      it "ignores a body supplied by the caller" do
        msg = message("what was actually said")

        post :report_message, params: { id: msg.id, description: "x", body: "what I claim was said" }

        expect(items.last).to include("what was actually said")
        expect(items.last).not_to include("what I claim was said")
      end

      it "refuses a message belonging to someone else" do
        other = create(:user)
        theirs = other.byte_conversations.create!(mode: :buddy, last_message_at: Time.current)
        msg = theirs.byte_messages.create!(user: other, direction: :inbound, state: :delivered, body: "hi")

        post :report_message, params: { id: msg.id, description: "x" }

        expect(response).to have_http_status(:not_found)
        expect(items).to be_empty
      end

      it "picks the oldest when more than one Todo list exists" do
        newer = List.create!(name: "TODO")
        UserList.create!(user: rocco, list: newer, is_owner: true)
        msg = message("hi")

        post :report_message, params: { id: msg.id, description: "x" }

        expect(items.last).to include("##{msg.id}")
        expect(newer.reload.list_items).to be_empty
      end

      it "says so rather than 500ing when there is no Todo list" do
        msg = message("hi")
        todo.destroy!

        post :report_message, params: { id: msg.id, description: "x" }

        expect(response).to have_http_status(:unprocessable_entity)
      end
    end
  end

  # `/today` — asking for the briefing by hand.
  describe "the today command" do
    let(:user)  { FactoryBot.create(:user, phone: "5550006000", role: :admin) }
    let!(:buddy) {
      user.byte_conversations.create!(mode: :buddy, name: "Byte", last_message_at: Time.current)
    }

    around { |ex| Sidekiq::Testing.fake! { ex.run } }

    before do
      allow(User).to receive(:me).and_return(user)
      user_id = user.id
      allow_any_instance_of(User).to receive(:me?) { |u| u.id == user_id }
      sign_in(user)
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(ActionCable.server).to receive(:broadcast)
    end

    def send_command(body, conversation: buddy)
      post(:create_message, params: { id: conversation.id, body: body })
    end

    def seeds(conversation = buddy)
      conversation.byte_messages.where("metadata->>'buddy_action' = 'today'")
    end

    # The briefing IS the answer and opens with a greeting, so nothing of its own
    # goes above it; the seed comes back hidden for the client to drop.
    it "posts a hidden hand-run briefing seed the turn can answer, and nothing else", :aggregate_failures do
      expect { send_command("/today") }.to change { seeds.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(seeds.last.metadata).to have_key("briefing")
      expect(seeds.last.metadata["source"]).to eq("quick_action")
      expect(buddy.byte_messages.where("metadata->>'kind' = 'system'")).to be_empty
      expect(buddy.byte_messages.where(body: "/today")).to be_empty
      body = JSON.parse(response.body)
      expect(body["metadata"]["hidden"]).to be(true)
      expect(body["id"]).to eq(seeds.last.id)
    end

    # Someone typing this at 2am has already answered the question the sleep
    # guard exists to ask. The dispatcher accepts either prefix.
    it "runs even while Buddy is asleep, and answers to the period form" do
      allow(Buddy::SleepGuard).to receive(:sleeping?).and_return(true)

      expect { send_command(".today") }.to change { seeds.count }.by(1)
    end

    context "in a thread that isn't Buddy's" do
      let!(:claude) {
        user.byte_conversations.create!(mode: :claude, name: "Claude", last_message_at: Time.current)
      }

      it "answers instead of briefing" do
        expect { send_command("/today", conversation: claude) }.not_to change { seeds(claude).count }

        expect(claude.byte_messages.last.body).to be_present
      end
    end
  end
end
