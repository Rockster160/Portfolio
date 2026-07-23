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
