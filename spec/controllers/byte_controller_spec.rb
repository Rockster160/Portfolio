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
  end

  describe "GET #messages" do
    before { sign_in rocco }

    it "returns the recent history in chronological order" do
      old_msg = rocco.byte_messages.create!(body: "old", direction: :outbound, created_at: 1.hour.ago)
      new_msg = rocco.byte_messages.create!(body: "new", direction: :inbound)

      get :messages

      ids = JSON.parse(response.body).fetch("messages").map { |m| m["id"] }
      expect(ids).to eq([old_msg.id, new_msg.id])
    end
  end
end
