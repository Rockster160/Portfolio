require "rails_helper"

RSpec.describe GamePlay::Stats do
  let(:user) { create(:user) }
  let(:play) {
    user.game_plays.create!(
      name: "Catan", client_uuid: SecureRandom.uuid, started_at: Time.current,
      players: [{ "name" => "Rocco" }, { "name" => "Chelsea" }], settings: { "dice" => "2d6" }
    )
  }

  def roll!(player, value, at:)
    play.game_rolls.create!(
      player_name: player, player_index: 0, value: value, dice: "2d6",
      rolled_at: at, client_uuid: SecureRandom.uuid
    )
  end

  describe "#distribution (2d6 exact convolution)" do
    it "matches the hand-computed triangle for 2d6" do
      roll!("Rocco", 7, at: 1.minute.ago)

      stats = described_class.for_play(play)
      by_value = stats[:distribution].index_by { |d| d[:value] }

      # P(sum) for 2d6 out of 36: 2/36 .. 7/36 .. 2/36. One roll of 7 -> expected 1 * 6/36.
      expect(by_value[7][:expected]).to eq((6.0 / 36).round(2))
      expect(by_value[2][:expected]).to eq((1.0 / 36).round(2))
      expect(by_value[12][:expected]).to eq((1.0 / 36).round(2))
      expect(by_value[7][:count]).to eq(1)
    end
  end

  describe "#turn_times" do
    it "attributes the gap between rolls to the player whose turn it was" do
      roll!("Rocco", 7, at: Time.zone.parse("2026-01-01 10:00:00"))
      roll!("Chelsea", 5, at: Time.zone.parse("2026-01-01 10:01:00"))
      roll!("Rocco", 9, at: Time.zone.parse("2026-01-01 10:03:00"))

      stats = described_class.for_play(play)

      expect(stats[:turn_times][:per_player]["Rocco"]).to eq(60.0)
      expect(stats[:turn_times][:per_player]["Chelsea"]).to eq(120.0)
    end
  end

  describe "#summary" do
    it "counts every die that hit the table and gives each player's mean, median, mode and SD" do
      [["Rocco", 7], ["Rocco", 7], ["Rocco", 4], ["Chelsea", 10], ["Chelsea", 12]].each_with_index do |(who, v), i|
        roll!(who, v, at: (10 - i).minutes.ago)
      end

      summary = described_class.for_play(play)[:summary]

      expect(summary[:rolls]).to eq(5)
      expect(summary[:dice_rolled]).to eq(10) # 2d6: two dice a roll
      expect(summary[:per_player]["Rocco"]).to include(count: 3, mean: 6.0, median: 7.0, modes: [7])
      # sample SD of 7, 7, 4: sqrt(((1 + 1 + 4) / 2)) = sqrt(3)
      expect(summary[:per_player]["Rocco"][:sd]).to eq(Math.sqrt(3).round(2))
      expect(summary[:per_player]["Chelsea"]).to include(count: 2, mean: 11.0, median: 11.0, modes: [])
      expect(summary[:table]).to include(count: 5, mean: 8.0, median: 7.0, modes: [7])
    end

    it "gives the fair-dice mean and SD for 2d6 (7 and sqrt(35/6))" do
      roll!("Rocco", 7, at: 1.minute.ago)

      expected = described_class.for_play(play)[:summary][:expected]

      expect(expected[:mean]).to eq(7.0)
      expect(expected[:sd]).to eq(Math.sqrt(35.0 / 6).round(2))
    end

    it "counts a one-off d20 as one die but keeps it out of the 2d6 averages" do
      roll!("Rocco", 8, at: 2.minutes.ago)
      play.game_rolls.create!(player_name: "Rocco", player_index: 0, value: 19, dice: "d20", rolled_at: 1.minute.ago, client_uuid: SecureRandom.uuid)

      summary = described_class.for_play(play)[:summary]

      expect(summary[:dice_rolled]).to eq(3)
      expect(summary[:per_player]["Rocco"]).to include(count: 1, mean: 8.0, sd: nil)
    end
  end

  describe "ignores voided rolls" do
    it "excludes a voided roll from both distribution and headlines" do
      roll!("Rocco", 7, at: 1.minute.ago).void!

      stats = described_class.for_play(play)

      expect(stats[:total_rolls]).to eq(0)
    end
  end
end
