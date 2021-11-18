# == Schema Information
#
# Table name: bowling_games
#
#  id         :integer          not null, primary key
#  game_data  :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

class BowlingGame < ApplicationRecord
  # DEFAULT_BOWLERS = ["Zoro"]
  DEFAULT_BOWLERS = ["Luffy", "Zoro", "Deku", "Law"]

  def game_data
    super || default_game_data
  end

  def default_game_data
    {}.tap do |data|
      DEFAULT_BOWLERS.each do |bowler_name|
        data[bowler_name] = {
          rolls: Array.new(10) { [] },
          # rolls: Array.new(9) { ["X"] } + [[]],
          card: false,
        }
      end
    end
  end
end
