require "rails_helper"

RSpec.describe "Games::Sync" do
  let(:user) { create(:user) }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def sync!(client_uuid, body)
    post "/games/plays/#{client_uuid}/sync", params: body, as: :json
    response.parsed_body
  end

  describe "starting a play offline" do
    it "creates the play and its Game ActionEvent from the first sync, with play_id present at creation" do
      uuid = SecureRandom.uuid

      expect {
        sync!(uuid, play: { name: "Catan", settings: { dice: "2d6" }, players: [{ name: "Rocco" }] })
      }.to change { user.game_plays.count }.by(1).and change { user.action_events.count }.by(1)

      play = user.game_plays.find_by!(client_uuid: uuid)
      expect(play.action_event.data["play_id"]).to eq(play.id)
      expect(response).to have_http_status(:success)
    end
  end

  describe "switching dice mode mid-game" do
    it "saves the new mode on a play that already exists" do
      uuid = SecureRandom.uuid
      sync!(uuid, play: { name: "Catan", settings: { dice: "2d6" }, players: [{ name: "Rocco" }] })

      sync!(uuid, play: { dice_mode: "virtual" })

      expect(user.game_plays.find_by!(client_uuid: uuid).dice_mode).to eq("virtual")
    end
  end

  describe "replaying a batch" do
    it "upserts rolls by client_uuid without creating duplicates" do
      play_uuid = SecureRandom.uuid
      sync!(play_uuid, play: { name: "Catan", players: [{ name: "Rocco" }] })
      roll_uuid = SecureRandom.uuid
      body = { rolls: [{ client_uuid: roll_uuid, player_name: "Rocco", player_index: 0, value: 7, dice: "2d6", rolled_at: Time.current.iso8601 }] }

      expect { sync!(play_uuid, body) }.to change(GameRoll, :count).by(1)
      expect { sync!(play_uuid, body) }.not_to(change(GameRoll, :count))
    end
  end

  describe "voiding a roll" do
    it "marks it voided rather than deleting it" do
      play_uuid = SecureRandom.uuid
      sync!(play_uuid, play: { name: "Catan", players: [{ name: "Rocco" }] })
      roll_uuid = SecureRandom.uuid
      sync!(play_uuid, rolls: [{ client_uuid: roll_uuid, player_name: "Rocco", player_index: 0, value: 7, dice: "2d6", rolled_at: Time.current.iso8601 }])

      sync!(play_uuid, voids: [{ kind: "roll", client_uuid: roll_uuid }])

      roll = GameRoll.find_by!(client_uuid: roll_uuid)
      expect(roll.voided_at).to be_present
      expect(GameRoll.live.count).to eq(0)
    end
  end

  describe "advancing the turn" do
    it "updates current_player_index on the existing play" do
      play_uuid = SecureRandom.uuid
      sync!(play_uuid, play: { name: "Catan", players: [{ name: "Rocco" }, { name: "Chelsea" }] })

      sync!(play_uuid, play: { current_player_index: 1 })

      expect(user.game_plays.find_by!(client_uuid: play_uuid).current_player_index).to eq(1)
    end
  end
end
