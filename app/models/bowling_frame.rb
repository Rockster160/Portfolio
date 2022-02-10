# == Schema Information
#
# Table name: bowling_frames
#
#  id               :integer          not null, primary key
#  frame_num        :integer
#  spare            :boolean          default(FALSE)
#  split            :boolean          default(FALSE)
#  strike           :boolean          default(FALSE)
#  strike_point     :integer
#  throw1           :integer
#  throw1_remaining :string
#  throw2           :integer
#  throw2_remaining :string
#  throw3           :integer
#  throw3_remaining :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  bowling_game_id  :integer
#

class BowlingFrame < ApplicationRecord
  belongs_to :game, class_name: "BowlingGame", inverse_of: :new_frames, foreign_key: :bowling_game_id
  # throwN == COUNT of how many pins were knocked down (For the shot itself- a spare will never be 10)
  # throwN_remaining == string list/array of the pins that are left AFTER the designated roll

  enum strike_point: {
    pocket:   0,
    brooklyn: 1,
  }

  def rolls
    roll1, roll2, roll3 = [throw1, throw2, throw3].map { |roll|
      roll.to_s.gsub("10", "X").gsub("0", "-").presence
    }
    roll2 = "/" if throw1.to_i < 10 && throw1.to_i + throw2.to_i == 10
    roll3 = "/" if roll1 == "X" && throw2.to_i < 10 && throw2.to_i + throw3.to_i == 10

    [roll1, roll2, roll3]
  end
end
