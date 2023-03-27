# == Schema Information
#
# Table name: climbs
#
#  id         :bigint           not null, primary key
#  data       :text
#  timestamp  :datetime
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint
#
class Climb < ApplicationRecord
  belongs_to :user

  MULTIPLIER_PER_V = 2

  scope :not_empty, -> { where.not(data: [nil, ""]) }

  def score
    data&.split(" ")&.sum { |v| score_for(v.to_i) } || 0
  end

  def score_for(go)
    @score_list ||= {}
    @score_list[go] ||= begin
      val = 1
      go.times { val *= MULTIPLIER_PER_V }
      val
    end
  end
end
