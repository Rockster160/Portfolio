require "rails_helper"

RSpec.describe WebhooksController, type: :controller do
  describe "the webhook" do
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

  # The mirror of byte_create. That posts a message AS Byte; this posts one as
  # the PERSON and lets Buddy take a real turn on it — the Mac `tell` CLI, a cron
  # job, a Jil bash step. It goes through ByteMessageIntake, so a message sent
  # this way behaves exactly like one typed in the PWA.
  describe "say" do
    let(:user)   { User.me }
    let(:secret) { "test-secret" }
    let!(:buddy_convo) {
      user.byte_conversations.create!(mode: :buddy, name: "Buddy", last_message_at: 1.hour.ago)
    }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("BYTE_LOCAL_SECRET", "").and_return(secret)
      request.env["HTTP_X_BYTE_SECRET"] = secret
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(BuddyDeliverWorker).to receive(:perform_async)
    end

    describe "POST #byte_say" do
      it "posts as the person and hands the turn to Buddy" do
        expect {
          post :byte_say, params: { user_id: user.id, body: "what's on my agenda?" }
        }.to change { buddy_convo.byte_messages.outbound.count }.by(1)

        expect(response).to have_http_status(:created)
        message = buddy_convo.byte_messages.outbound.last
        expect(message.body).to eq("what's on my agenda?")
        expect(message).to be_sent
        expect(BuddyDeliverWorker).to have_received(:perform_async).with(message.id)
      end

      # The PRIMARY thread, which is a different question from `default_for`
      # (the newest live one) and used to be answered the same way. Nobody typed
      # this — a cron job or the Mac `tell` CLI did — so it belongs where the
      # person reads, not wherever they happened to be last.
      it "lands in the primary Buddy thread, not whatever default_for returns" do
        newer = user.byte_conversations.create!(mode: :buddy, name: "Later", last_message_at: Time.current)
        # Asserted before the post, because landing a message in a thread bumps
        # its activity and would make it the newest by the time we looked.
        expect(ByteConversation.default_for(user)).to eq(newer)

        post :byte_say, params: { user_id: user.id, body: "hello" }

        expect(buddy_convo.byte_messages.outbound.count).to eq(1)
        expect(newer.byte_messages.outbound.count).to eq(0)
      end

      it "follows the primary somewhere else once one is chosen" do
        newer = user.byte_conversations.create!(mode: :buddy, name: "Later", last_message_at: Time.current)
        ByteConversation.pin_primary!(newer)

        post :byte_say, params: { user_id: user.id, body: "hello" }

        expect(newer.byte_messages.outbound.count).to eq(1)
        expect(buddy_convo.byte_messages.outbound.count).to eq(0)
      end

      it "honours an explicit conversation_id" do
        other = user.byte_conversations.create!(mode: :buddy, name: "Other", last_message_at: Time.current)

        post :byte_say, params: { user_id: user.id, conversation_id: buddy_convo.id, body: "here please" }

        expect(buddy_convo.byte_messages.outbound.count).to eq(1)
        expect(other.byte_messages.outbound.count).to eq(0)
      end

      # A CLI has no business steering a claude/bash thread on the Mac it ran from.
      it "refuses a conversation that isn't Buddy's" do
        claude = user.byte_conversations.create!(mode: :claude, name: "Code")

        post :byte_say, params: { user_id: user.id, conversation_id: claude.id, body: "rm -rf" }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(claude.byte_messages.count).to eq(0)
      end

      it "401s without the shared secret" do
        request.env["HTTP_X_BYTE_SECRET"] = "wrong"
        post :byte_say, params: { user_id: user.id, body: "nope" }
        expect(response).to have_http_status(:unauthorized)
      end

      it "rejects an empty body rather than posting a blank bubble" do
        post :byte_say, params: { user_id: user.id, body: "   " }

        expect(response).to have_http_status(:bad_request)
        expect(buddy_convo.byte_messages.count).to eq(0)
      end

      # The whole reason this shares ByteMessageIntake with the PWA: a CLI
      # "5m pasta" should get the instant timer, not a model round trip.
      it "takes the timer fast path the same way a typed message does" do
        allow(::Buddy::Timers).to receive(:quick_set!)

        post :byte_say, params: { user_id: user.id, body: "5m pasta" }

        expect(::Buddy::Timers).to have_received(:quick_set!)
        expect(BuddyDeliverWorker).not_to have_received(:perform_async)
        expect(buddy_convo.byte_messages.outbound.last).to be_sent
      end

      # `tell --hidden alarm`. The metadata arrives as a JSON STRING in a form
      # field, so this is the seam where a boolean can turn into the word "true"
      # — and both readers of the flag are strict: the `readable` scope compares
      # against 'true' and the PWA drops on `=== true`.
      describe "--hidden" do
        def say_hidden!(body)
          post :byte_say, params: {
            user_id:  user.id,
            body:     body,
            metadata: { hidden: true }.to_json,
          }
        end

        it "keeps it a boolean through the JSON round trip" do
          say_hidden!("alarm")

          expect(buddy_convo.byte_messages.outbound.last.metadata["hidden"]).to be(true)
        end

        # The server sends hidden rows down like any other and the CLIENT drops
        # them (byte/index.js upsertMessage), so the wire payload is where the
        # flag has to survive — a broadcast or a history page that lost it would
        # render the message as an ordinary bubble.
        it "carries the flag on the wire, which is where it's acted on" do
          say_hidden!("alarm")

          expect(buddy_convo.byte_messages.outbound.last.as_wire[:metadata]["hidden"]).to be(true)
        end

        it "still does the thing that was asked for" do
          allow(::Buddy::Alarms).to receive(:quick_ring!)

          say_hidden!("alarm")

          expect(::Buddy::Alarms).to have_received(:quick_ring!)
        end

        it "keeps the source it always had rather than replacing it" do
          say_hidden!("alarm")

          expect(buddy_convo.byte_messages.outbound.last.metadata["source"]).to eq("cli")
        end
      end

      it "queues instead of dispatching while Buddy is asleep" do
        allow(::Buddy::SleepGuard).to receive(:sleeping?).and_return(true)

        post :byte_say, params: { user_id: user.id, body: "you awake?" }

        expect(buddy_convo.byte_messages.outbound.last).to be_queued
        expect(BuddyDeliverWorker).not_to have_received(:perform_async)
      end
    end
  end

  describe "buddy lookups" do
    let(:user)   { User.me }
    let(:secret) { "test-secret" }

    before do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("BYTE_LOCAL_SECRET", "").and_return(secret)
      request.env["HTTP_X_BYTE_SECRET"] = secret
    end

    describe "GET #byte_agenda" do
      it "401s without the shared secret" do
        request.env["HTTP_X_BYTE_SECRET"] = "wrong"
        get :byte_agenda, params: { user_id: user.id, range: "today" }
        expect(response).to have_http_status(:unauthorized)
      end

      it "returns a compact body + count for :upcoming" do
        get :byte_agenda, params: { user_id: user.id, range: "upcoming" }
        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json).to include("range" => "upcoming", "count" => a_kind_of(Integer), "body" => a_kind_of(String))
      end

      it "accepts a free-form q that runs through AgendaItem.query" do
        get :byte_agenda, params: { user_id: user.id, q: "is:today" }
        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["range"]).to eq("is:today")
      end

      it "400s on an unknown range" do
        get :byte_agenda, params: { user_id: user.id, range: "yesteryear" }
        expect(response).to have_http_status(:bad_request)
      end
    end

    describe "GET #byte_weather" do
      it "401s without the shared secret" do
        request.env["HTTP_X_BYTE_SECRET"] = "wrong"
        get :byte_weather, params: { user_id: user.id }
        expect(response).to have_http_status(:unauthorized)
      end

      # Fetching and formatting moved into WeatherService (see
      # weather_service_spec for the one-liner itself); the endpoint is now just
      # a pass-through with an availability guard.
      it "returns 503 when there's no forecast to be had" do
        allow(WeatherService).to receive(:summary).and_return(nil)
        get :byte_weather, params: { user_id: user.id }
        expect(response).to have_http_status(:service_unavailable)
      end

      it "renders the service's one-liner" do
        allow(WeatherService).to receive(:summary)
          .and_return("currently 72°F, partly cloudy. today high 85°F / low 56°F, chance of rain 20%.")

        get :byte_weather, params: { user_id: user.id }

        expect(response).to be_successful
        json = JSON.parse(response.body)
        expect(json["body"]).to include("72°F", "partly cloudy", "high 85°F", "low 56°F", "chance of rain 20%")
      end
    end
  end

  describe "conversations" do
    let(:user)  { User.me }
    let(:convo) { user.byte_conversations.create!(name: "target", mode: :claude, metadata: { cwd: "/old/path" }) }
    let(:secret) { "test-secret-32chars-long" }

    before do
      stub_const("ByteLocal::TIMEOUT_SECONDS", 1)
      allow(ByteLocal).to receive(:secret).and_return(secret)
      request.headers["X-Byte-Secret"] = secret
      request.headers["Content-Type"]  = "application/json"
    end

    describe "PATCH #byte_update_conversation" do
      it "merges metadata rather than replacing it" do
        patch :byte_update_conversation, params: {
          id:       convo.id,
          metadata: { cwd: "/new/path" }.to_json,
        }

        expect(response).to be_successful
        convo.reload
        expect(convo.metadata["cwd"]).to eq("/new/path")
      end

      it "leaves untouched metadata keys alone" do
        convo.update!(metadata: { cwd: "/old", claude_session_id: "abc" })

        patch :byte_update_conversation, params: {
          id:       convo.id,
          metadata: { cwd: "/new" }.to_json,
        }

        convo.reload
        expect(convo.metadata["cwd"]).to eq("/new")
        expect(convo.metadata["claude_session_id"]).to eq("abc")
      end

      it "rejects requests without a valid secret" do
        request.headers["X-Byte-Secret"] = "wrong"
        patch :byte_update_conversation, params: { id: convo.id, metadata: {} }
        expect(response).to have_http_status(:unauthorized)
      end

      it "returns 404 for an unknown conversation" do
        patch :byte_update_conversation, params: { id: -1, metadata: { cwd: "/x" }.to_json }
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
