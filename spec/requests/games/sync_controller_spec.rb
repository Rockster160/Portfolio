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

  describe "changing a play mid-game" do
    it "saves dice mode and turn changes on a play that already exists" do
      uuid = SecureRandom.uuid
      sync!(uuid, play: { name: "Catan", settings: { dice: "2d6" }, players: [{ name: "Rocco" }, { name: "Chelsea" }] })

      sync!(uuid, play: { dice_mode: "virtual" })
      sync!(uuid, play: { current_player_index: 1 })

      play = user.game_plays.find_by!(client_uuid: uuid)
      expect(play.dice_mode).to eq("virtual")
      expect(play.current_player_index).to eq(1)
    end

    it "starts a play with its game's phases and keeps where the table is in them", :aggregate_failures do
      uuid = SecureRandom.uuid
      phases = [{ name: "Emerge", steps: ["Nodes Pulse"] }, { name: "Swarm", laps: 2, steps: ["2", "1", "0"] }]
      sync!(uuid, play: { name: "Slime Colony", settings: { phases: phases }, players: [{ name: "Rocco" }] })

      sync!(uuid, play: { phase_state: { round: 2, phase: 1, step: 2, lap: 1, turn: 0, lead: 0 } })
      sync!(uuid, play: { current_player_index: 0 })

      play = user.game_plays.find_by!(client_uuid: uuid)
      expect(play.phases).to eq(phases.map(&:deep_stringify_keys))
      expect(play.phase_state).to eq({ "round" => 2, "phase" => 1, "step" => 2, "lap" => 1, "turn" => 0, "lead" => 0 })
    end

    it "moves the start, and the Game event's time with it", :aggregate_failures do
      uuid = SecureRandom.uuid
      sync!(uuid, play: { name: "Catan", players: [{ name: "Rocco" }], started_at: 5.minutes.ago.iso8601 })
      earlier = 40.minutes.ago.change(usec: 0)

      sync!(uuid, play: { started_at: earlier.iso8601 })

      play = user.game_plays.find_by!(client_uuid: uuid)
      expect(play.started_at).to eq(earlier)
      expect(play.action_event.reload.timestamp).to eq(earlier)
    end

    it "leaves the start alone when the time sent is still to come" do
      uuid = SecureRandom.uuid
      sync!(uuid, play: { name: "Catan", players: [{ name: "Rocco" }] })
      started = user.game_plays.find_by!(client_uuid: uuid).started_at

      sync!(uuid, play: { started_at: 2.hours.from_now.iso8601 })

      expect(user.game_plays.find_by!(client_uuid: uuid).started_at).to eq(started)
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
end
