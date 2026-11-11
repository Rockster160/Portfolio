require "rails_helper"

RSpec.describe GamePlay do
  let(:user) { create(:user) }

  def build_play(**attrs)
    user.game_plays.create!({
      name:        "Catan",
      client_uuid: SecureRandom.uuid,
      started_at:  Time.current,
      players:     [{ "name" => "Rocco" }, { "name" => "Chelsea" }],
      settings:    { "scoring" => "individual" },
    }.merge(attrs))
  end

  describe "#ensure_action_event!" do
    it "creates the Game ActionEvent with play_id present at creation" do
      play = build_play
      event = play.ensure_action_event!

      expect(event.name).to eq("Game")
      expect(event.notes).to eq("Catan")
      expect(event.data["play_id"]).to eq(play.id)
      expect(play.reload.action_event_id).to eq(event.id)
    end

    it "is idempotent" do
      play = build_play
      first = play.ensure_action_event!
      second = play.ensure_action_event!
      expect(second.id).to eq(first.id)
      expect(user.action_events.count).to eq(1)
    end
  end

  describe "#finish!" do
    it "writes final scores onto the linked ActionEvent and computes the winner from them" do
      play = build_play(settings: { "scoring" => "individual", "win" => "high" })
      play.ensure_action_event!

      play.finish!(
        final_scores: { "Rocco" => 55, "Chelsea" => 42 },
        started_at: play.started_at, ended_at: play.started_at + 90.minutes, duration_minutes: 90
      )

      expect(play.reload.status).to eq("finished")
      expect(play.winner_names).to eq(["Rocco"])
      event = play.action_event.reload
      expect(event.data["players"]).to eq({ "Rocco" => 55, "Chelsea" => 42 })
      expect(event.data["duration"]).to eq("90")
      expect(event.data["play_id"]).to eq(play.id)
    end

    it "writes a teams breakdown with nil player scores and computes a team winner" do
      play = build_play(settings: { "scoring" => "teams", "win" => "high" })
      play.ensure_action_event!

      play.finish!(
        final_scores: { "Red" => 12, "Blue" => 8 },
        started_at: play.started_at, ended_at: play.started_at + 30.minutes
      )

      expect(play.winner_names).to eq(["Red"])
      event = play.action_event.reload
      expect(event.data["teams"]).to eq({ "Red" => 12, "Blue" => 8 })
      expect(event.data["players"]).to eq({ "Rocco" => nil, "Chelsea" => nil })
    end

    it "writes a single table score with no computed winner - nothing to compare it against" do
      play = build_play(settings: { "scoring" => "table", "win" => "high" })
      play.ensure_action_event!

      play.finish!(
        final_scores: { "table" => 96 },
        started_at: play.started_at, ended_at: play.started_at + 45.minutes
      )

      expect(play.winner_names).to eq([])
      event = play.action_event.reload
      expect(event.data["score"]).to eq(96)
      expect(event.data["players"]).to eq({ "Rocco" => nil, "Chelsea" => nil })
    end

    it "logs the round a phased game ended on, and no rounds for a game without phases" do
      phased = build_play(settings: { "phases" => [{ "name" => "Emerge" }] }, phase_state: { "round" => 3 })
      plain = build_play(phase_state: { "round" => 3 })
      [phased, plain].each do |play|
        play.ensure_action_event!
        play.finish!(final_scores: { "Rocco" => 1 }, started_at: play.started_at, ended_at: Time.current)
      end

      expect(phased.action_event.reload.data["rounds"]).to eq(3)
      expect(plain.action_event.reload.data).not_to have_key("rounds")
    end

    it "logs setup time apart from the game's own duration" do
      play = build_play(setup_started_at: 70.minutes.ago, started_at: 60.minutes.ago)
      play.ensure_action_event!

      play.finish!(final_scores: { "Rocco" => 1 }, started_at: play.started_at, ended_at: Time.current, duration_minutes: 60)

      expect(play.action_event.reload.data).to include("setup_duration" => "10", "duration" => "60")
    end
  end

  describe "#compute_winner_names" do
    it "returns nothing when win is none" do
      play = build_play(settings: { "scoring" => "individual", "win" => "none" })
      expect(play.compute_winner_names({ "Rocco" => 55, "Chelsea" => 42 })).to eq([])
    end

    it "handles ties" do
      play = build_play(settings: { "scoring" => "individual", "win" => "high" })
      expect(play.compute_winner_names({ "Rocco" => 50, "Chelsea" => 50 })).to contain_exactly("Rocco", "Chelsea")
    end

    it "picks the lowest score when win is low" do
      play = build_play(settings: { "scoring" => "individual", "win" => "low" })
      expect(play.compute_winner_names({ "Rocco" => 55, "Chelsea" => 42 })).to eq(["Chelsea"])
    end
  end

  describe "#abandon!" do
    it "marks the ActionEvent abandoned without clearing existing scores" do
      play = build_play
      play.ensure_action_event!
      play.game_score_entries.create!(player_name: "Rocco", delta: 5, entered_at: Time.current, client_uuid: SecureRandom.uuid)

      play.abandon!

      expect(play.reload.status).to eq("abandoned")
      expect(play.action_event.reload.data["abandoned"]).to be(true)
    end
  end
end
