require "rails_helper"

RSpec.describe ByteController, type: :controller do
  describe "the controller" do
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

      # Routines used to be a whole inline panel in the drawer, which is what
      # crowded it enough to squash the New conversation button. Both managers
      # are a row that opens a dialog now.
      it "puts routines and reminders behind drawer rows rather than inline" do
        sign_in rocco

        get :show

        expect(response.body).to include("data-byte-open-routines", "data-byte-open-reminders")
        expect(response.body).to include("data-byte-routines-modal", "data-byte-reminders-modal")
        expect(response.body).not_to include("byte-routines-hint")
      end

      # The picker offered 7 of 21 buddy-enabled automations with no search box,
      # no scroll and no explanation, which read as an arbitrary handful.
      it "gives the Jil picker a search box and says what it leaves out" do
        sign_in rocco

        get :show

        expect(response.body).to include("data-byte-jil-search")
        expect(response.body).to include("Only automations that fire by name are listed")
      end

      # Rendered inline rather than applied by JS after boot, so a reload doesn't
      # flash the default size and reflow.
      it "paints the saved text size on the first frame" do
        rocco.update!(byte_font_scale: 130)
        sign_in rocco

        get :show

        expect(response.body).to include("--byte-font-scale: 1.3")
        expect(response.body).to include("data-byte-font-bigger")
      end

      # The stepper first sat loose in the drawer nav, where a control among a
      # list of destinations read as something that had been dropped there.
      it "puts the text-size control behind a Settings row like the others" do
        sign_in rocco

        get :show

        expect(response.body).to include("data-byte-open-settings", "data-byte-settings-modal")
        expect(response.body).not_to include("byte-drawer-stepper")
      end

      # Copy that names the companion must name THIS thread's companion. The
      # drawer hints said "Ask Byte to save a new one" to everyone, which is
      # simply the wrong pet's name for two of the three people who use this.
      it "names the open thread's companion in copy, never a hardcoded one" do
        chelsea = create(:user, id: 58_128)
        sign_in chelsea

        get :show

        body = response.body
        expect(body).to include("Ask <span data-buddy-name-slot>Moss</span>")
        expect(body).not_to match(/Ask Byte|Tell Byte|need Byte/)
      end

      # …and the slots have to move on a thread switch, which is the client's
      # job. This just proves the server marks them for it.
      it "marks that copy so a thread switch can repaint it" do
        sign_in rocco

        get :show

        expect(response.body.scan("data-buddy-name-slot").length).to be >= 4
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

      it "renders the wall surface: the routines, and the control that sets who's on it" do
        get :kiosk

        expect(response).to be_successful
        expect(response.body).to include('data-kiosk="true"')
        expect(response.body).to include("byte-kiosk-pad")
        expect(response.body).to include("data-kiosk-who")
      end

      # The chat page and the kiosk are one template, so the flag has to actually
      # be off everywhere else or the normal app loses its header.
      it "leaves the chat page alone" do
        get :show

        expect(response.body).to include('data-kiosk="false"')
        expect(response.body).not_to include("byte-kiosk-pad")
      end

      def button_names
        response.body.scan(/data-kiosk-routine="\d+"[^>]*>([^<]+)</).flatten.map(&:strip)
      end

      # A wall tablet is read from across a room and tapped without stopping, so a
      # button only has to say which one it is. The description used to ride
      # underneath as a second line of small print, which made every button taller
      # and none of them clearer.
      it "puts the name on a button and nothing else" do
        routine!("Prep Printer", position: 0, description: "Powers it on, waits, then preheats")

        get :kiosk

        expect(button_names).to eq(["Prep Printer"])
        expect(response.body).not_to include("byte-kiosk-btn-sub")
        # Still reachable on a long-press / hover, just not taking up the face.
        expect(response.body).to include('title="Powers it on, waits, then preheats"')
      end

      # A routine carrying a monitor key gets a LIVE button: kiosk.js subscribes
      # to the key and repaints the label and colour from whatever the Jil task
      # broadcasts, the same contract the Fae, Whisper and list trigger buttons
      # run on. The saved name is only what shows for the beat before the socket
      # answers, so the server still has to render it.
      it "marks a monitored routine's button so the pad subscribes to it" do
        routine!("Yoga Lights", position: 0, monitor: "yoga-lights")

        get :kiosk

        expect(response.body).to include('data-kiosk-monitor="yoga-lights"')
        expect(button_names).to eq(["Yoga Lights"])
      end

      it "leaves an ordinary routine's button unsubscribed" do
        routine!("Prep Printer", position: 0)

        get :kiosk

        expect(response.body).not_to include("data-kiosk-monitor")
      end

      # A matter of space, not principle. Quick is a popover you open, scan and
      # dismiss, so it carries everything; the wall is a fixed pad with room for a
      # handful of big targets, and every routine ever saved buries the three you
      # walk up and press.
      it "takes only the starred ones, in the order they were dragged into" do
        routine!("Wind Down", position: 1)
        routine!("Prep Printer", position: 0)
        routine!("Almost Never")

        get :kiosk

        expect(button_names).to eq(["Prep Printer", "Wind Down"])
      end

      it "leaves off the ones that are switched off, starred or not" do
        routine!("Muted", position: 0, enabled: false)

        get :kiosk

        expect(button_names).to be_empty
      end

      # They may well have routines and just none starred, so "save one" would
      # send them off to do a thing they've already done.
      it "says what's actually missing when nothing is pinned" do
        routine!("Saved but unstarred")

        get :kiosk

        expect(button_names).to be_empty
        expect(response.body).to include("Nothing pinned yet")
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

      # Which companion is on the wall IS which thread it's pinned to — the theme
      # on the row decides the character, the name, the palette and the voice.
      # Without the pin it opens whichever thread spoke last, which is a
      # different companion any time a watch fires somewhere else.
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

        it "falls back to the newest when nothing is pinned" do
          get :kiosk

          expect(response.body).to include(%(data-initial-conversation-id="#{newest.id}"))
        end

        it "falls back rather than opening one that's since been archived" do
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

      # The service worker refuses to cache a page without this, so a kiosk
      # missing it silently loses the offline boot that makes it dependable.
      it "carries the shell marker the service worker caches on" do
        get :kiosk

        expect(response.body).to include('<meta name="byte-shell" content="ok">')
      end

      it "forbids anyone who can't open Byte at all" do
        sign_in create(:user)

        get :kiosk

        expect(response).to have_http_status(:forbidden)
      end

      it "lets Chelsea put one on a wall too" do
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

      it "points the wall at the chosen thread" do
        convo = buddy!("kitchen")

        post :pin_kiosk_conversation, params: { conversation_id: convo.id }

        expect(response).to be_successful
        expect(convo.reload).to be_kiosk
      end

      # "Which one is out there" is a single fact. Two pinned would make what the
      # tablet opens on depend on row order.
      it "unpins whichever was there before" do
        first  = buddy!("kitchen")
        second = buddy!("desk")
        ByteConversation.pin_kiosk!(first)

        post :pin_kiosk_conversation, params: { conversation_id: second.id }

        expect(rocco.byte_conversations.kiosk.pluck(:id)).to eq([second.id])
      end

      # The kiosk can't show one, so pinning it would leave the wall on a thread
      # it silently falls back off of every load.
      it "refuses a claude thread" do
        claude = rocco.byte_conversations.create!(name: "shell", mode: :claude)

        post :pin_kiosk_conversation, params: { conversation_id: claude.id }

        expect(response).to have_http_status(:not_found)
        expect(claude.reload).not_to be_kiosk
      end

      it "refuses someone else's" do
        theirs = create(:user).byte_conversations.create!(name: "theirs", mode: :buddy)

        post :pin_kiosk_conversation, params: { conversation_id: theirs.id }

        expect(response).to have_http_status(:not_found)
        expect(theirs.reload).not_to be_kiosk
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

      it "points everything self-initiated at the chosen thread" do
        first  = buddy!("Byte")
        second = buddy!("Moss")

        post :pin_primary_conversation, params: { conversation_id: second.id }

        expect(response).to be_successful
        expect(second.reload).to be_primary
        expect(ByteConversation.for_self_initiated(rocco)).to eq(second)
        expect(first.reload).not_to be_primary
      end

      it "takes it off whichever held it before" do
        first  = buddy!("Byte")
        second = buddy!("Moss")
        ByteConversation.pin_primary!(first)

        post :pin_primary_conversation, params: { conversation_id: second.id }

        expect(rocco.byte_conversations.primary.pluck(:id)).to eq([second.id])
      end

      # Both rows have to repaint on a second device, or the one that lost it
      # keeps showing the marker.
      it "broadcasts the loser as well as the winner" do
        first  = buddy!("Byte")
        second = buddy!("Moss")
        ByteConversation.pin_primary!(first)

        post :pin_primary_conversation, params: { conversation_id: second.id }

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

      it "reports the resolved one on the conversations index" do
        buddy!("Byte")
        second = buddy!("Moss")
        ByteConversation.pin_primary!(second)

        get :list_conversations

        expect(response.parsed_body["primary_id"]).to eq(second.id)
      end

      it "reports the default one when nothing has been chosen" do
        first = buddy!("Byte")
        buddy!("Moss")

        get :list_conversations

        expect(response.parsed_body["primary_id"]).to eq(first.id)
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

      it "refuses a batch bigger than MAX_FILES" do
        files = Array.new(ByteImageIntake::MAX_FILES + 1) { image }

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

    # Claude / Bash / Jarvis all hand off to the owner's Mac, and
    # create_conversation has always pinned everyone else to :buddy. The form
    # offered them anyway, so Chelsea picked "Claude" and silently got a Buddy
    # thread — a menu whose choices don't mean anything.
    describe "the new-conversation form" do
      render_views

      it "offers the owner every mode" do
        sign_in rocco

        get :show

        expect(response.body).to include('value="claude"', 'value="bash"', 'value="jarvis"')
      end

      it "offers a buddy-only member no mode choice at all" do
        sign_in create(:user, id: 58_128)

        get :show

        expect(response.body).not_to include('value="bash"')
        expect(response.body).not_to include('value="jarvis"')
        expect(response.body).to include('name="mode" value="buddy"')
      end

      it "lets them pick which companion the thread wears" do
        sign_in rocco

        get :show

        expect(response.body).to include('name="buddy_theme"')
        pets = Buddy::Themes.keys
        pets.each { |theme| expect(response.body).to include(%(value="#{theme}")) }
      end
    end

    describe "POST #create_conversation" do
      it "wears the companion they picked" do
        sign_in rocco

        post :create_conversation, params: { mode: "buddy", buddy_theme: "suki" }

        expect(rocco.byte_conversations.order(:id).last.buddy_theme).to eq("suki")
      end

      # The account default is what it falls back to, exactly as before.
      it "falls back to the account's own pet when none is named" do
        chelsea = create(:user, id: 58_128)
        sign_in chelsea

        post :create_conversation, params: { mode: "buddy" }

        expect(chelsea.byte_conversations.order(:id).last.buddy_theme).to eq("moss")
      end

      # The case dirty-tracking can't see: "byte" is the column default, so
      # choosing it on a non-Byte account looks identical to choosing nothing.
      it "honours picking Byte on an account whose default is not Byte" do
        chelsea = create(:user, id: 58_128)
        sign_in chelsea

        post :create_conversation, params: { mode: "buddy", buddy_theme: "byte" }

        expect(chelsea.byte_conversations.order(:id).last.buddy_theme).to eq("byte")
      end

      it "ignores a theme that isn't a real companion" do
        sign_in rocco

        post :create_conversation, params: { mode: "buddy", buddy_theme: "gremlin" }

        expect(rocco.byte_conversations.order(:id).last.buddy_theme).to eq("byte")
      end

      # Server-side enforcement is what actually matters; the form is just no
      # longer lying about it.
      it "still pins a buddy-only member to a Buddy thread whatever they post" do
        chelsea = create(:user, id: 58_128)
        sign_in chelsea

        post :create_conversation, params: { mode: "bash" }

        expect(chelsea.byte_conversations.order(:id).last.mode).to eq("buddy")
      end

      it "leaves a non-Buddy thread without a chosen pet" do
        sign_in rocco

        post :create_conversation, params: { mode: "bash", buddy_theme: "suki" }

        convo = rocco.byte_conversations.order(:id).last
        expect(convo.mode).to eq("bash")
        expect(convo.buddy_theme).to eq("byte")
      end
    end

    describe "POST #font_scale" do
      it "saves it and hands back what it settled on" do
        sign_in rocco

        post :font_scale, params: { scale: 140 }

        expect(response.parsed_body["scale"]).to eq(140)
        expect(rocco.reload.byte_font_scale).to eq(140)
      end

      it "clamps an absurd value rather than erroring" do
        sign_in rocco

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

      # Any icon the picker can offer, not a fixed six — the whole pool, custom
      # household uploads included.
      it "takes anything the picker could have handed back" do
        message = relay_message

        post :react_message, params: { id: message.id, emoji: "🍕" }

        expect(response).to be_successful
        expect(Buddy::Reactions.of(message.reload).pluck("emoji")).to eq(["🍕"])
      end

      it "refuses free text the picker could never produce" do
        message = relay_message

        post :react_message, params: { id: message.id, emoji: "lol nice one" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(Buddy::Reactions.of(message.reload)).to be_empty
      end

      # The row is most-recently-used, so reacting has just reordered it.
      it "hands back the reordered picker row" do
        message = relay_message

        post :react_message, params: { id: message.id, emoji: "🍕" }

        recents = response.parsed_body["recents"]
        expect(recents.first).to eq("🍕")
        expect(recents.length).to eq(Buddy::Reactions::RECENT_LIMIT)
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
        expect(response.parsed_body["errors"].first).to include("Todo")
      end
    end
  end

  # `/today` — asking for the briefing by hand.
  #
  # The scheduled one is a recurring reminder and the hero chip that used to run
  # one is long gone, so the only remaining way in was hoping the model reached
  # for the `today_briefing` tool — which its own description tells it not to.
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

    it "posts a briefing seed the turn can answer" do
      expect { send_command("/today") }.to change { seeds.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(seeds.last.body).to include("What's on for TODAY")
    end

    # A hand-run is exempt from the sleep guard: someone typing this at 2am has
    # already answered the question the guard exists to ask.
    it "runs even while Buddy is asleep" do
      allow(Buddy::SleepGuard).to receive(:sleeping?).and_return(true)

      expect { send_command("/today") }.to change { seeds.count }.by(1)
    end

    it "is marked as a hand-run rather than the scheduled one" do
      send_command("/today")

      expect(seeds.last.metadata["source"]).to eq("quick_action")
    end

    # The briefing IS the answer, and it opens with a greeting. A line above
    # saying it's coming is the receipt the tool already refuses.
    it "says nothing of its own — no acknowledgement above the briefing" do
      send_command("/today")

      expect(buddy.byte_messages.where("metadata->>'kind' = 'system'")).to be_empty
    end

    it "hands back the seed, which the client drops on sight" do
      send_command("/today")

      body = JSON.parse(response.body)
      expect(body["metadata"]["hidden"]).to be(true)
      expect(body["id"]).to eq(seeds.last.id)
    end

    # The dispatcher accepts either prefix; period is closer to the space bar.
    it "answers to the period form too" do
      expect { send_command(".today") }.to change { seeds.count }.by(1)
    end

    it "never reaches the model as an ordinary message" do
      send_command("/today")

      expect(buddy.byte_messages.where(body: "/today")).to be_empty
    end

    context "in a thread that isn't Buddy's" do
      let!(:claude) {
        user.byte_conversations.create!(mode: :claude, name: "Claude", last_message_at: Time.current)
      }

      it "says so instead of briefing" do
        expect { send_command("/today", conversation: claude) }.not_to change { seeds(claude).count }

        expect(claude.byte_messages.last.body).to include("Buddy thing")
      end
    end
  end
end
