require "rails_helper"

RSpec.describe ByteController, type: :controller do
  let(:rocco) { User.me }

  before do
    allow(ByteLocal).to receive(:deliver).and_return(nil)
    sign_in rocco
  end

  describe "GET #list_conversations" do
    it "returns the user's active conversations plus a default_id" do
      one = rocco.byte_conversations.create!(name: "one", mode: :claude, last_message_at: 1.minute.ago)
      two = rocco.byte_conversations.create!(name: "two", mode: :bash,   last_message_at: 5.minutes.ago)

      get :list_conversations

      expect(response).to be_successful
      payload = JSON.parse(response.body)
      ids = payload["conversations"].map { |c| c["id"] }
      # Newer activity floats to the top.
      expect(ids.first(2)).to eq([one.id, two.id])
      expect(payload["default_id"]).to eq(one.id)
    end
  end

  describe "POST #read_conversation" do
    let(:convo) {
      rocco.byte_conversations.create!(name: "one", mode: :buddy, last_read_at: 1.hour.ago)
    }

    def landed
      convo.byte_messages.create!(user: rocco, direction: :inbound, state: :delivered, body: "hi")
    end

    it "clears that thread's count and reports the new total" do
      landed
      landed

      post :read_conversation, params: { id: convo.id }

      expect(response).to be_successful
      payload = JSON.parse(response.body)
      expect(payload["unread_count"]).to eq(0)
      expect(payload["unread_total"]).to eq(0)
      expect(convo.reload.unread_count).to eq(0)
    end

    it "leaves other threads counting" do
      other = rocco.byte_conversations.create!(name: "two", mode: :claude, last_read_at: 1.hour.ago)
      other.byte_messages.create!(user: rocco, direction: :inbound, state: :delivered, body: "x")
      landed

      post :read_conversation, params: { id: convo.id }

      expect(JSON.parse(response.body)["unread_total"]).to eq(1)
    end

    # A read is a fact about ONE device's screen. Broadcasting it would take the
    # badge off a phone because a browser at the desk opened the thread.
    it "does not broadcast the change to other clients" do
      expect(controller).not_to receive(:broadcast_convo_change)

      post :read_conversation, params: { id: convo.id }
    end

    it "404s on someone else's conversation" do
      stranger = User.create!(
        username:              "stranger-#{SecureRandom.hex(4)}",
        password:              "abcd1234!",
        password_confirmation: "abcd1234!",
      )
      theirs = stranger.byte_conversations.create!(name: "nope", mode: :buddy)

      post :read_conversation, params: { id: theirs.id }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET #list_conversations unread" do
    it "carries the server-side count, so a reload doesn't start at zero" do
      convo = rocco.byte_conversations.create!(name: "one", mode: :buddy, last_read_at: 1.hour.ago)
      convo.byte_messages.create!(user: rocco, direction: :inbound, state: :delivered, body: "hi")

      get :list_conversations

      row = JSON.parse(response.body)["conversations"].find { |c| c["id"] == convo.id }
      expect(row["unread_count"]).to eq(1)
    end
  end

  describe "POST #create_conversation" do
    it "creates a claude-mode conversation by default" do
      expect {
        post :create_conversation, params: { name: "New chat" }
      }.to change { rocco.byte_conversations.count }.by(1)

      created = JSON.parse(response.body)
      expect(created["name"]).to eq("New chat")
      expect(created["mode"]).to eq("claude")
      expect(response).to have_http_status(:created)
    end

    it "respects an explicit mode" do
      post :create_conversation, params: { name: "Terminal", mode: "bash" }
      expect(JSON.parse(response.body)["mode"]).to eq("bash")
    end

    it "falls back to claude for an unknown mode value" do
      post :create_conversation, params: { name: "?", mode: "quantum" }
      expect(JSON.parse(response.body)["mode"]).to eq("claude")
    end

    it "names a blank buddy conversation after the Buddy (Byte theme)" do
      # A new buddy thread seeds its theme from ByteConversation.default_theme_for.
      allow(ByteConversation).to receive(:default_theme_for).and_return("byte")
      post :create_conversation, params: { mode: "buddy" }
      expect(JSON.parse(response.body)["name"]).to eq("Byte")
    end

    it "uses the Moss name when the user's Buddy default is moss" do
      allow(ByteConversation).to receive(:default_theme_for).and_return("moss")
      post :create_conversation, params: { mode: "buddy" }
      expect(JSON.parse(response.body)["name"]).to eq("Moss")
    end

    it "keeps an explicit name on a buddy conversation" do
      post :create_conversation, params: { name: "Groceries", mode: "buddy" }
      expect(JSON.parse(response.body)["name"]).to eq("Groceries")
    end
  end

  describe "PATCH #update_conversation" do
    let!(:convo) { rocco.byte_conversations.create!(name: "old", mode: :claude) }

    it "renames a conversation" do
      patch :update_conversation, params: { id: convo.id, name: "renamed" }
      expect(response).to be_successful
      expect(convo.reload.name).to eq("renamed")
    end

    it "stashes adopt-session metadata via update" do
      patch :update_conversation, params: {
        id: convo.id,
        metadata: { claude_session_id: "abc123" },
      }
      expect(response).to be_successful
      # ActionController params serialise the nested hash as strings.
      body = JSON.parse(response.body)
      expect(body["metadata"]["claude_session_id"]).to eq("abc123")
    end
  end

  describe "DELETE #archive_conversation" do
    it "flips archived: true on the record" do
      convo = rocco.byte_conversations.create!(name: "toss", mode: :claude)
      delete :archive_conversation, params: { id: convo.id }
      expect(response).to have_http_status(:no_content)
      expect(convo.reload.archived).to eq(true)
    end
  end

  describe "POST #create_message routing" do
    it "scopes the message to the specified conversation" do
      convo = rocco.byte_conversations.create!(name: "target", mode: :claude)

      expect {
        post :create_message, params: { body: "hi there", conversation_id: convo.id }
      }.to change { convo.byte_messages.count }.by(1)

      payload = JSON.parse(response.body)
      expect(payload["conversation_id"]).to eq(convo.id)
    end

    it "dispatches Jarvis-mode conversations through ByteJarvisWorker" do
      convo = rocco.byte_conversations.create!(name: "jarv", mode: :jarvis)

      expect(ByteLocal).not_to receive(:deliver)
      expect(ByteJarvisWorker).to receive(:perform_async).with(kind_of(Integer))

      post :create_message, params: { body: "turn on the lights", conversation_id: convo.id }
      expect(response).to have_http_status(:created)
    end
  end

  # Buddy answering from the shape of the last few turns rather than the request
  # in front of it is a real failure mode, so there needs to be a way to cut the
  # thread's history loose without losing anything durable.
  describe "POST #create_message /compact" do
    let(:convo) { rocco.byte_conversations.create!(name: "buddy", mode: :buddy) }

    def say(text)
      convo.byte_messages.create!(
        user: rocco, direction: :inbound, state: :delivered, body: text, metadata: { "kind" => "buddy" },
      )
    end

    def compact!
      post :create_message, params: { body: "/compact", conversation_id: convo.id }
    end

    it "hides prior turns from the model without deleting them" do
      say("something from earlier")
      expect(Buddy::GPT::History.build(convo, upto: nil)).not_to be_empty

      expect { compact! }.not_to(change { convo.byte_messages.where("body = 'something from earlier'").count })
      expect(Buddy::GPT::History.build(convo.reload, upto: nil)).to be_empty
    end

    it "clears any carried recap rather than handing it forward" do
      convo.update!(metadata: { "buddy_recap" => "they had a rough week", "buddy_recap_at" => 1.day.ago.iso8601(6) })

      compact!

      expect(convo.reload.metadata).not_to have_key("buddy_recap")
      expect(convo.metadata["buddy_recap_at"]).to be_present
    end

    it "leaves durable memory and this thread's notes alone" do
      memory = BuddyMemory.create!(user: rocco, content: "prefers oat milk")
      convo.update!(buddy_memories: "keep this thread work-only")

      compact!

      expect(memory.reload.content).to eq("prefers oat milk")
      expect(convo.reload.buddy_memories).to eq("keep this thread work-only")
    end

    # Prod 2513: `/reset` rendered two identical bubbles off one row.
    #
    # `ack` both BROADCASTS its message and returns it as the response, so the
    # client sees the same row twice. That's fine as long as it can tell the
    # two apart — and the tell is `direction`. A slash command stores no
    # outbound record on purpose, so what comes back is an inbound system
    # message rather than an echo of what was sent; the client keys off that to
    # know it must not adopt the reply as the sent message's own bubble.
    #
    # Here because it's a contract the front end depends on and nothing else
    # would notice it changing. The other half - an ordinary send answering
    # with the OUTBOUND row and its local_id - is in byte_controller_spec.
    it "answers a slash command with an inbound message, not an echo of the command" do
      compact!

      expect(response.parsed_body["direction"]).to eq("inbound")
      expect(response.parsed_body.dig("metadata", "kind")).to eq("system")
      # The command itself is deliberately not stored, so there is nothing for
      # the client to reconcile its optimistic bubble against.
      expect(convo.byte_messages.where(direction: :outbound)).to be_empty
    end

    # The command exists for Buddy answering from the shape of the last few
    # turns instead of from the request in front of it, and Buddy::TopicState is
    # that shape in one sentence, riding in the prompt under a heading saying it
    # is what's happening right now. Clearing the transcript and keeping the
    # summary of it leaves behind the half that was doing the steering.
    it "takes the topic line with it, not just the transcript" do
      convo.update_columns(buddy_topic: "planning the greenhouse refit", buddy_topic_at: 1.hour.ago)
      say("one")

      compact!

      expect(convo.reload.buddy_topic).to be_nil
      expect(Buddy::Personality.for(rocco, conversation: convo)).not_to include("What you're on right now")
    end

    it "answers with what it dropped, and says the thread itself is still there" do
      say("one")
      say("two")

      compact!

      body = response.parsed_body["body"]
      expect(body).to match(/last 2 turns won't be sent/i)
      expect(body).to match(/still on screen/i)
    end

    # It's a `kind: :system` message sitting in the same bubble the pet uses, so
    # writing it in a companion's voice makes it the WRONG companion in three
    # threads out of four. Prod 2615 opened "Fresh start from here" in a Suki
    # thread, which is Byte's register and nobody who was in the room.
    it "reports as the app and names the companion instead of speaking as one" do
      convo.update!(buddy_theme: "suki")
      say("one")

      compact!

      body = response.parsed_body["body"]
      expect(body).to include("Suki")
      expect(body).not_to match(/\AFresh start from here/i)
    end

    # `/reset` is the name that describes what it does; the other two are what
    # it was called before.
    it "answers to /reset and /forget the same way" do
      %w[/reset /forget].each { |cmd|
        convo.update!(metadata: {})
        say("something")

        post :create_message, params: { body: cmd, conversation_id: convo.id }

        expect(convo.reload.metadata["buddy_recap_at"]).to be_present, "expected #{cmd} to set a reset point"
        expect(Buddy::GPT::History.build(convo, upto: nil)).to be_empty
      }
    end

    it "declines outside Buddy mode instead of silently doing nothing" do
      other = rocco.byte_conversations.create!(name: "claude", mode: :claude)

      post :create_message, params: { body: "/compact", conversation_id: other.id }

      expect(response.parsed_body["body"]).to match(/Buddy thing/i)
      expect(other.reload.metadata["buddy_recap_at"]).to be_nil
    end
  end

  # A model round trip costs several seconds. That's invisible on a 20-minute
  # timer and most of the countdown on a 10-second one — and it's several seconds
  # during which the model might not call set_timer at all, which is exactly what
  # prod was doing.
  describe "POST #create_message timer fast path" do
    let(:convo) { rocco.byte_conversations.create!(name: "buddy", mode: :buddy) }

    around { |ex| Sidekiq::Testing.fake! { ex.run } }

    before do
      allow(MonitorChannel).to receive(:broadcast_to)
      allow(BuddyDeliverWorker).to receive(:perform_async)
    end

    def send_message(text)
      post :create_message, params: { body: text, conversation_id: convo.id }
    end

    def chip
      convo.byte_messages.where("metadata->>'kind' = 'buddy_activity'").last
    end

    it "sets the timer without waking the model" do
      send_message("5m pasta")

      expect(BuddyDeliverWorker).not_to have_received(:perform_async)
      expect(rocco.timers.where(kind: :countdown).count).to eq(1)
      expect(chip.body).to eq("Byte set a 5 min timer for pasta ⏲")
    end

    it "still posts the person's own message" do
      send_message("5m")

      expect(convo.byte_messages.where(direction: :outbound).last.body).to eq("5m")
      expect(response).to have_http_status(:created)
    end

    it "hands anything less plainly shaped to the model" do
      send_message("20 minutes of stretching")

      expect(BuddyDeliverWorker).to have_received(:perform_async)
      expect(rocco.timers.where(kind: :countdown).count).to eq(0)
    end

    it "does not fast-path outside Buddy mode" do
      claude = rocco.byte_conversations.create!(name: "claude", mode: :claude)

      post :create_message, params: { body: "5m", conversation_id: claude.id }

      expect(rocco.timers.where(kind: :countdown).count).to eq(0)
    end
  end

  describe "GET #messages scoped to conversation" do
    it "filters the history by conversation_id" do
      a = rocco.byte_conversations.create!(name: "A", mode: :claude)
      b = rocco.byte_conversations.create!(name: "B", mode: :claude)
      a.byte_messages.create!(user: rocco, body: "in-a-1", direction: :outbound)
      a.byte_messages.create!(user: rocco, body: "in-a-2", direction: :outbound)
      b.byte_messages.create!(user: rocco, body: "in-b-1", direction: :outbound)

      get :messages, params: { conversation_id: a.id }
      bodies = JSON.parse(response.body)["messages"].map { |m| m["body"] }
      expect(bodies).to match_array(["in-a-1", "in-a-2"])
    end
  end
end
