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

  describe "ignores voided rolls" do
    it "excludes a voided roll from both distribution and headlines" do
      roll!("Rocco", 7, at: 1.minute.ago).void!

      stats = described_class.for_play(play)

      expect(stats[:total_rolls]).to eq(0)
    end
  end
end
