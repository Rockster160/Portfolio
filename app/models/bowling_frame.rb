# == Schema Information
#
# Table name: bowling_frames
#
#  id               :integer          not null, primary key
#  frame_num        :integer
#  spare            :boolean          default(FALSE)
#  split            :boolean          default(FALSE)
#  strike           :boolean          default(FALSE)
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
end
