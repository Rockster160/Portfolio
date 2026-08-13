require "rails_helper"

RSpec.describe ByteController, type: :controller do
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
