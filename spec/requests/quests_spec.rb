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

  describe "the home screen icon" do
    let(:board) { user.quest_boards.create!(name: "Animal Crossing") }
    let(:png) { "\x89PNG\r\n\x1A\n".b + ("pixels" * 10) }
    let(:data_url) { "data:image/png;base64,#{Base64.strict_encode64(png)}" }

    def set_icon
      patch "/quests/#{board.id}", params: { icon: "🌟", icon_color: "#224466", icon_png: data_url }, as: :json
    end

    def install_path(name, token: board.install_token)
      "/quests/#{board.id}/#{name}?t=#{token}"
    end

    it "keeps the drawn icon and serves it, named and scoped to the board" do
      set_icon
      expect(response).to have_http_status(:ok)
      board.reload
      expect(board.icon).to eq("🌟")
      expect(board.icon_color).to eq("#224466")
      expect(board.icon_png.b).to eq(png)
      icon_url = response.parsed_body["icon_url"]
      expect(icon_url).to start_with("/quests/#{board.id}/icon.png?")

      get "/logout"
      get icon_url
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("image/png")
      expect(response.body.b).to eq(png)

      get install_path("manifest.webmanifest")
      manifest = ActiveSupport::JSON.decode(response.body)
      expect(manifest).to include(
        "name"        => "Animal Crossing",
        "start_url"   => "/quests/#{board.id}?source=pwa",
        "scope"       => "/quests/#{board.id}",
        "theme_color" => "#224466",
      )
      expect(manifest["icons"].pluck("src")).to all(eq(icon_url))
    end

    it "keeps the name when only the icon changes, and the icon when only the name does" do
      set_icon
      expect(board.reload.name).to eq("Animal Crossing")

      patch "/quests/#{board.id}", params: { name: "Stardew" }, as: :json
      expect(board.reload).to have_attributes(name: "Stardew", icon: "🌟")
    end

    it "goes back to the site's icon when cleared" do
      set_icon
      patch "/quests/#{board.id}", params: { icon: "", icon_color: "", icon_png: "" }, as: :json
      expect(board.reload.icon_png).to be_nil

      get install_path("manifest.webmanifest")
      expect(ActiveSupport::JSON.decode(response.body)["icons"].pluck("src")).to include("/favicon/android-chrome-512x512.png")
      get install_path("icon.png")
      expect(response).to have_http_status(:not_found)
    end

    it "links the board's own manifest and icon from its page" do
      set_icon
      get "/quests/#{board.id}"
      expect(response.body).to include(
        "/quests/#{board.id}/manifest.webmanifest?t=",
        "rel=\"apple-touch-icon\" sizes=\"180x180\" href=\"/quests/#{board.id}/icon.png?t=",
        "content=\"Animal Crossing\"",
      )
    end

    it "refuses something that isn't a PNG, or is too big" do
      patch "/quests/#{board.id}", params: { icon: "🌟", icon_png: "data:image/png;base64,#{Base64.strict_encode64("GIF89a")}" }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)

      huge = "\x89PNG\r\n\x1A\n".b + ("x" * QuestBoard::MAX_ICON_BYTES)
      patch "/quests/#{board.id}", params: { icon: "🌟", icon_png: "data:image/png;base64,#{Base64.strict_encode64(huge)}" }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
      expect(board.reload.icon_png).to be_nil
    end

    it "opens nothing without the board's own token" do
      set_icon
      other = user.quest_boards.create!(name: "Stardew")
      get "/logout"

      get "/quests/#{board.id}/manifest.webmanifest"
      expect(response).to have_http_status(:not_found)
      get install_path("icon.png", token: other.install_token)
      expect(response).to have_http_status(:not_found)
    end
  end
end
