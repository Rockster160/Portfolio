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

  scope :not_empty, -> { where.not(data: [nil, ""]) }

  def self.best
    all.max_by(&:score)
  end

  def score
    data&.split(" ")&.sum { |v| score_for(v.to_i) } || 0
  end

  def score_for(v_index)
    ::Calculator.fibonacci(v_index.to_i+2)
  end
end
