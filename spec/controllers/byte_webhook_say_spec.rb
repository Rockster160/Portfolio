require "rails_helper"

# The mirror of byte_create. That posts a message AS Byte; this posts one as
# the PERSON and lets Buddy take a real turn on it — the Mac `tell` CLI, a cron
# job, a Jil bash step. It goes through ByteMessageIntake, so a message sent
# this way behaves exactly like one typed in the PWA.
RSpec.describe WebhooksController, type: :controller do
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
