require "rails_helper"

RSpec.describe GamesController do
  let(:user) { create(:user) }

  before { post login_path, params: { user: { username: user.username, password: "password123" } } }

  def build_play(**attrs)
    user.game_plays.create!({
      name:        "Catan",
      client_uuid: SecureRandom.uuid,
      started_at:  1.hour.ago,
      players:     [{ "name" => "Rocco" }, { "name" => "Chelsea" }],
      settings:    { "scoring" => "individual" },
    }.merge(attrs))
  end

  describe "GET /games" do
    it "succeeds with templates and an active play" do
      template = user.game_templates.create!(name: "Catan")
      build_play(game_template_id: template.id)

      get games_path
      expect(response).to have_http_status(:success)
    end

    it "handles a legacy Game event with no data at all" do
      user.action_events.create!(name: "Game", notes: "Risk", timestamp: 1.year.ago, data: nil)

      get games_path

      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /games/new" do
    it "succeeds" do
      get new_game_path
      expect(response).to have_http_status(:success)
    end
  end

  describe "GET /games/plays/:id" do
    it "renders the live play page for an active play, bootstrap included" do
      play = build_play
      get game_play_path(play.id)

      expect(response).to have_http_status(:success)
      expect(response.body).to include("play-bootstrap")
      expect(response.body).to include(play.client_uuid)
    end

    it "renders the read-only stats page for a finished play" do
      play = build_play(status: :finished, winner_names: ["Rocco"], final_scores: { "Rocco" => 55 })

      get game_play_path(play.id)

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Rocco")
    end

    it "links to editing and replaying a finished play" do
      play = build_play(status: :finished)

      get game_play_path(play.id)

      expect(response.body).to include(edit_finish_game_play_path(play.id))
      expect(response.body).to include(replay_game_play_path(play.id))
    end
  end

  describe "POST /games/plays/:id/replay" do
    it "starts a new play immediately with the same players, rotated" do
      play = build_play(status: :finished, players: [{ "name" => "Rocco" }, { "name" => "Chelsea" }])

      expect { post replay_game_play_path(play.id) }.to change { user.game_plays.active.count }.by(1)

      new_play = user.game_plays.active.order(started_at: :desc).first
      expect(new_play.players.pluck("name")).to eq(["Chelsea", "Rocco"])
      expect(new_play.settings).to eq(play.settings)
      expect(response).to redirect_to(game_play_path(new_play.id))
    end
  end

  describe "GET /games/plays/:id/finish" do
    it "prefills current score totals" do
      play = build_play
      play.game_score_entries.create!(player_name: "Rocco", delta: 5, entered_at: Time.current, client_uuid: SecureRandom.uuid)
      play.game_score_entries.create!(player_name: "Rocco", delta: 3, entered_at: Time.current, client_uuid: SecureRandom.uuid)

      get edit_finish_game_play_path(play.id)

      expect(response).to have_http_status(:success)
      expect(response.body).to include('value="8"')
    end

    it "falls back to the play's saved final_scores when there are no live score entries (a backfilled play)" do
      play = build_play(status: :finished, final_scores: { "Rocco" => 130, "Chelsea" => 140 }, started_at: 3.months.ago)

      get edit_finish_game_play_path(play.id)

      expect(response.body).to include('value="130"')
      expect(response.body).to include('value="140"')
    end

    it "has no manual winner control - the winner is computed from the scores, never picked by hand" do
      play = build_play(status: :finished, winner_names: ["Chelsea"])

      get edit_finish_game_play_path(play.id)

      expect(response.body).not_to include('name="winner_names')
    end

    it "never computes duration against Time.current for a finished play" do
      play = build_play(status: :finished, started_at: 3.months.ago, duration_minutes: nil)

      get edit_finish_game_play_path(play.id)

      expect(response.body).not_to match(/name="duration_minutes" value="\d{4,}"/)
    end
  end

  describe "POST /games/plays/:client_uuid/finish" do
    it "finalizes the play and computes the winner from the submitted scores (json)" do
      play = build_play(settings: { "scoring" => "individual", "win" => "high" })
      play.ensure_action_event!

      post finish_game_play_path(play.client_uuid), params: {
        final_scores:     { "Rocco" => 55, "Chelsea" => 42 },
        ended_at:         Time.current.iso8601,
        duration_minutes: 45,
      }, as: :json

      expect(response).to have_http_status(:success)
      expect(play.reload.status).to eq("finished")
      expect(response.parsed_body["winner_names"]).to eq(["Rocco"])
      expect(response.parsed_body["stats"]).to be_present
    end

    it "compares the form's string scores as numbers, so 130 beats 55" do
      play = build_play(settings: { "scoring" => "individual", "win" => "high" })
      play.ensure_action_event!

      post finish_game_play_path(play.client_uuid), params: {
        final_scores: { "Rocco" => "55", "Chelsea" => "130" },
        ended_at:     Time.current.iso8601,
      }

      play.reload
      expect(play.winner_names).to eq(["Chelsea"])
      expect(play.final_scores).to eq({ "Rocco" => 55, "Chelsea" => 130 })
    end

    it "keeps a blank score box as no score rather than zero" do
      play = build_play(settings: { "scoring" => "individual", "win" => "low" })
      play.ensure_action_event!

      post finish_game_play_path(play.client_uuid), params: {
        final_scores: { "Rocco" => "12", "Chelsea" => "" },
        ended_at:     Time.current.iso8601,
      }

      play.reload
      expect(play.final_scores).to eq({ "Rocco" => 12, "Chelsea" => nil })
      expect(play.winner_names).to eq(["Rocco"])
    end

    it "redirects to the show page on a real form submission" do
      play = build_play
      play.ensure_action_event!

      post finish_game_play_path(play.client_uuid), params: {
        final_scores: { "Rocco" => 55, "Chelsea" => 42 },
      }

      expect(response).to redirect_to(game_play_path(play.id))
      expect(play.reload.status).to eq("finished")
    end
  end

  describe "POST /games/plays/:client_uuid/abandon" do
    it "marks the play abandoned and redirects to the index on a real form submission" do
      play = build_play
      play.ensure_action_event!

      post abandon_game_play_path(play.client_uuid)

      expect(play.reload.status).to eq("abandoned")
      expect(response).to redirect_to(games_path)
    end
  end

  describe "GET /games/legacy/:id" do
    it "renders a manually-logged event with no play" do
      event = user.action_events.create!(name: "Game", notes: "Risk", timestamp: 1.year.ago, data: { "players" => { "Rocco" => 10 } })

      get legacy_game_path(event.id)

      expect(response).to have_http_status(:success)
      expect(response.body).to include("Risk")
    end
  end

  describe "GET /games/player_colors" do
    it "returns the most recently seen colour per name" do
      build_play(players: [{ "name" => "Chelsea", "color" => "#aaaaaa" }], client_uuid: SecureRandom.uuid, created_at: 1.day.ago)
      build_play(players: [{ "name" => "chelsea", "color" => "#bbbbbb" }], client_uuid: SecureRandom.uuid, created_at: 1.hour.ago)

      get games_player_colors_path

      expect(response.parsed_body).to eq({ "chelsea" => "#bbbbbb" })
    end
  end

  describe "another user's play" do
    it "is not reachable" do
      other = create(:user)
      play = other.game_plays.create!(name: "X", client_uuid: SecureRandom.uuid, players: [])

      get game_play_path(play.id)

      expect(response).not_to have_http_status(:success)
    end
  end
end
