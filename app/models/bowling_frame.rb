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
  has_one :set, class_name: "BowlingSet", through: :game
  has_one :bowler, through: :game
  # throwN == COUNT of how many pins were knocked down (For the shot itself- a spare will never be 10)
  # throwN_remaining == string list/array of the pins that are left AFTER the designated roll

  enum strike_point: {
    pocket:   0,
    brooklyn: 1,
  }

  def complete?
    rolls.none?(&:nil?) || rolls.include?("X")
  end

  def rolls
    roll1, roll2, roll3 = [throw1, throw2, throw3].map { |roll|
      roll.to_s.gsub("10", "X").gsub("0", "-").presence
    }
    roll2 = "/" if throw1.to_i < 10 && throw1.to_i + throw2.to_i == 10
    roll3 = "/" if roll1 == "X" && throw2.to_i < 10 && throw2.to_i + throw3.to_i == 10

    tenth? ? [roll1, roll2, roll3] : [roll1, roll2]
  end

  def tenth?
    frame_num == 10
  end

  def pin_fall_details
    return [] if throw1_remaining.nil?
    return [[throw1_fallen, throw2_fallen]] if throw3_remaining.nil?

    [].tap do |fall|
      if throw1_remaining == "[]" # Strike
        fall << [throw1_fallen]

        if throw2_remaining == "[]" # Strike
          fall << [throw2_fallen]
          fall << [throw3_fallen]
        else
          fall << [throw2_fallen, throw3_fallen]
        end
      else
        fall << [throw1_fallen, throw2_fallen]
        fall << [throw3_fallen]
      end
    end
  end

  def fallen(remaining)
    remaining = JSON.parse(remaining) rescue nil if remaining.is_a?(String)
    return unless remaining.is_a?(Array)

    (1..10).to_a - remaining
  end

  def throw1_fallen
    return @throw1_fallen if defined?(@throw1_fallen)

    @throw1_fallen = fallen(throw1_remaining)
  end

  def throw2_fallen
    return @throw2_fallen if defined?(@throw2_fallen)

    @throw2_fallen = fallen(throw2_remaining)
  end

  def throw3_fallen
    return @throw3_fallen if defined?(@throw3_fallen)

    @throw3_fallen = fallen(throw3_remaining)
  end
end
