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

      expect { compact! }.not_to change { convo.byte_messages.where("body = 'something from earlier'").count }
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

    it "answers with what it dropped" do
      say("one")
      say("two")

      compact!

      expect(JSON.parse(response.body)["body"]).to match(/cleared 2 turns/i)
    end

    it "declines outside Buddy mode instead of silently doing nothing" do
      other = rocco.byte_conversations.create!(name: "claude", mode: :claude)

      post :create_message, params: { body: "/compact", conversation_id: other.id }

      expect(JSON.parse(response.body)["body"]).to match(/Buddy thing/i)
      expect(other.reload.metadata["buddy_recap_at"]).to be_nil
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
