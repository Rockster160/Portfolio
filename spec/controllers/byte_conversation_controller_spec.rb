require "rails_helper"

RSpec.describe ByteController, type: :controller do
  let(:rocco) { User.me }

  before do
    allow(ByteLocal).to receive(:deliver).and_return(nil)
    sign_in rocco
  end

  describe "GET #list_conversations" do
    # The server-side unread count rides along, so a reload doesn't start at zero.
    it "returns the user's active conversations, newest first, with a default_id and unread counts" do
      one = rocco.byte_conversations.create!(name: "one", mode: :claude, last_message_at: 1.minute.ago, last_read_at: 1.hour.ago)
      two = rocco.byte_conversations.create!(name: "two", mode: :bash,   last_message_at: 5.minutes.ago)
      one.byte_messages.create!(user: rocco, direction: :inbound, state: :delivered, body: "hi")
      one.update_columns(last_message_at: 1.minute.ago)

      get :list_conversations

      expect(response).to be_successful
      payload = JSON.parse(response.body)
      ids = payload["conversations"].map { |c| c["id"] }
      expect(ids.first(2)).to eq([one.id, two.id])
      expect(payload["default_id"]).to eq(one.id)
      expect(payload["conversations"].find { |c| c["id"] == one.id }["unread_count"]).to eq(1)
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

  describe "POST #create_conversation" do
    it "creates a claude-mode conversation by default, respecting a known explicit mode" do
      expect {
        post :create_conversation, params: { name: "New chat" }
      }.to change { rocco.byte_conversations.count }.by(1)

      created = JSON.parse(response.body)
      expect(created["name"]).to eq("New chat")
      expect(created["mode"]).to eq("claude")
      expect(response).to have_http_status(:created)

      [["bash", "bash"], ["quantum", "claude"]].each do |mode, stored|
        post :create_conversation, params: { name: "T", mode: mode }
        expect(JSON.parse(response.body)["mode"]).to eq(stored)
      end
    end

    # A new buddy thread seeds its theme from ByteConversation.default_theme_for.
    it "names a blank buddy conversation after the user's default Buddy, keeping an explicit name" do
      [["byte", nil, "Byte"], ["moss", nil, "Moss"], ["moss", "Groceries", "Groceries"]].each do |theme, name, expected|
        allow(ByteConversation).to receive(:default_theme_for).and_return(theme)
        post :create_conversation, params: { mode: "buddy", name: name }.compact
        expect(JSON.parse(response.body)["name"]).to eq(expected)
      end
    end
  end

  describe "PATCH #update_conversation" do
    let!(:convo) { rocco.byte_conversations.create!(name: "old", mode: :claude) }

    it "renames a conversation and stashes adopt-session metadata" do
      patch :update_conversation, params: { id: convo.id, name: "renamed", metadata: { claude_session_id: "abc123" } }

      expect(response).to be_successful
      expect(convo.reload.name).to eq("renamed")
      expect(JSON.parse(response.body)["metadata"]["claude_session_id"]).to eq("abc123")
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

  # A way to cut the thread's history loose without losing anything durable.
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

    # A slash command stores no outbound record, so what comes back is an inbound
    # system message the client must not adopt as the sent message's bubble.
    # Buddy::TopicState is the shape of the last few turns in one sentence, so it
    # goes too; durable memory and the thread's notes stay.
    it "hides prior turns, the recap and the topic from the model while keeping durable memory", :aggregate_failures do
      say("something from earlier")
      convo.update!(
        metadata:       { "buddy_recap" => "they had a rough week", "buddy_recap_at" => 1.day.ago.iso8601(6) },
        buddy_memories: "keep this thread work-only",
      )
      convo.update_columns(buddy_topic: "planning the greenhouse refit", buddy_topic_at: 1.hour.ago)
      memory = BuddyMemory.create!(user: rocco, content: "prefers oat milk")
      expect(Buddy::GPT::History.build(convo, upto: nil)).not_to be_empty

      expect { compact! }.not_to(change { convo.byte_messages.where("body = 'something from earlier'").count })

      convo.reload
      expect(Buddy::GPT::History.build(convo, upto: nil)).to be_empty
      expect(convo.metadata).not_to have_key("buddy_recap")
      expect(convo.metadata["buddy_recap_at"]).to be_present
      expect(convo.buddy_topic).to be_nil
      expect(Buddy::Personality.for(rocco, conversation: convo)).not_to include("planning the greenhouse refit")
      expect(memory.reload.content).to eq("prefers oat milk")
      expect(convo.buddy_memories).to eq("keep this thread work-only")

      expect(response.parsed_body["direction"]).to eq("inbound")
      expect(response.parsed_body.dig("metadata", "kind")).to eq("system")
      expect(convo.byte_messages.where(direction: :outbound)).to be_empty
    end

    # A `kind: :system` message sits in the pet's bubble, so it names the
    # thread's companion rather than speaking as one.
    it "names the thread's companion in its reply" do
      convo.update!(buddy_theme: "suki")
      say("one")

      compact!

      expect(response.parsed_body["body"]).to include("Suki")
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

    it "declines outside Buddy mode, answering rather than silently doing nothing" do
      other = rocco.byte_conversations.create!(name: "claude", mode: :claude)

      post :create_message, params: { body: "/compact", conversation_id: other.id }

      expect(response.parsed_body["body"]).to be_present
      expect(other.reload.metadata["buddy_recap_at"]).to be_nil
    end
  end

  # A model round trip costs several seconds, most of the countdown on a short
  # timer, so a plainly-shaped timer request skips the model.
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

    it "sets the timer without waking the model, still posting the person's own message" do
      send_message("5m pasta")

      expect(BuddyDeliverWorker).not_to have_received(:perform_async)
      expect(rocco.timers.where(kind: :countdown).sole.name).to eq("pasta")
      expect(chip).to be_present
      expect(convo.byte_messages.where(direction: :outbound).last.body).to eq("5m pasta")
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
