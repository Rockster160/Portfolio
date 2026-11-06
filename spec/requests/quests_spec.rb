require "rails_helper"

RSpec.describe "Quest board", type: :request do
  let(:user) { User.me }
  let(:password) { "password123" }

  def sign_in
    user.update!(password: password, password_confirmation: password)
    post "/login", params: { user: { username: user.username, password: password } }
  end

  before { sign_in }

  describe "boards" do
    it "lists boards and makes a new one" do
      user.quest_boards.create!(name: "Stardew")

      get "/quests"
      expect(response.body).to include("Stardew")

      expect { post "/quests", params: { name: "Animal Crossing" } }.to change { user.quest_boards.count }.by(1)
      board = user.quest_boards.find_by!(name: "Animal Crossing")
      expect(response).to redirect_to("/quests/#{board.id}")
    end

    it "serves a board page" do
      board = user.quest_boards.create!(name: "Animal Crossing")

      get "/quests/#{board.id}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-board-id=\"#{board.id}\"", "Animal Crossing", "data-icon-stack")
    end

    it "renames and deletes a board" do
      board = user.quest_boards.create!(name: "Quests")

      patch "/quests/#{board.id}", params: { name: "Animal Crossing" }, as: :json
      expect(board.reload.name).to eq("Animal Crossing")

      expect { delete "/quests/#{board.id}", as: :json }.to change { user.quest_boards.count }.by(-1)
    end

    it "keeps another user's board out of reach" do
      other = User.create!(username: "questother", password: password, password_confirmation: password)
      board = other.quest_boards.create!(name: "Theirs")

      put "/quests/#{board.id}/state", params: { data: { "updatedAt" => 1, "items" => [] } }, as: :json
      expect(response).not_to have_http_status(:ok)
      expect(board.reload.rev).to eq(0)
    end
  end

  describe "the stored board" do
    let(:board) { user.quest_boards.create!(name: "Animal Crossing") }
    let(:path) { "/quests/#{board.id}/state" }

    it "starts empty and keeps what the phone saves" do
      get path
      expect(response.parsed_body).to eq("data" => {}, "rev" => 0)

      data = { "updatedAt" => 100, "items" => [{ "id" => "q1", "name" => "Wish on {n} stars" }], "log" => [] }
      put path, params: { data: data }, as: :json
      expect(response.parsed_body).to eq("rev" => 1)

      get path
      expect(response.parsed_body).to eq("data" => data, "rev" => 1)
    end

    it "keeps each board's copy to itself" do
      other = user.quest_boards.create!(name: "Stardew")
      put path, params: { data: { "updatedAt" => 100, "items" => [{ "id" => "q1" }] } }, as: :json

      get "/quests/#{other.id}/state"
      expect(response.parsed_body["data"]).to eq({})
    end

    it "hands back the newer board instead of letting an older copy roll it back" do
      put path, params: { data: { "updatedAt" => 200, "items" => [] } }, as: :json
      put path, params: { data: { "updatedAt" => 150, "items" => [{ "id" => "old" }] } }, as: :json

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["data"]).to eq("updatedAt" => 200, "items" => [])
    end
  end

  describe "hooks" do
    it "logs an ActionEvent that wakes event listeners, and deletes it on undo" do
      allow(::ActionEventNotifier).to receive(:notify)

      expect {
        post "/quests/hooks", params: {
          kind:  :event,
          name:  "Stars",
          notes: "Wished on 20",
          data:  { quests: true, count: 20 },
        }, as: :json
      }.to change { user.action_events.count }.by(1)

      event = user.action_events.order(:id).last
      expect(event).to have_attributes(name: "Stars", notes: "Wished on 20")
      expect(event.data).to include("quests" => true, "count" => 20)
      expect(response.parsed_body).to eq("event_id" => event.id)
      expect(::ActionEventNotifier).to have_received(:notify).with(user, event, :added, anything)

      expect { delete "/quests/hooks/#{event.id}", as: :json }.to change { user.action_events.count }.by(-1)
      expect(::ActionEventNotifier).to have_received(:notify).with(user, event, :removed, anything)
    end

    it "fires a named trigger with the quest's data" do
      allow(::Jil).to receive(:trigger)

      post "/quests/hooks", params: { kind: :trigger, trigger: "mushrooms_done", data: { count: 5 } }, as: :json

      expect(response.parsed_body).to eq("ok" => true)
      expect(::Jil).to have_received(:trigger).with(user, "mushrooms_done", { "count" => 5 }, anything)
    end

    it "treats an undo for an event that's already gone as done" do
      delete "/quests/hooks/0", as: :json
      expect(response.parsed_body).to eq("ok" => true)
    end

    it "refuses a hook it doesn't know" do
      post "/quests/hooks", params: { kind: :email }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
