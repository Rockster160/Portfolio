# == Schema Information
#
# Table name: climbs
#
#  id            :bigint           not null, primary key
#  data          :text
#  scores        :json
#  timestamp     :datetime
#  total_pennies :integer
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  user_id       :bigint
#
class Climb < ApplicationRecord
  belongs_to :user

  scope :not_empty, -> { where.not(data: [nil, ""]) }

  def self.best
    all.max_by(&:total_pennies)
  end

  def total
    if total_pennies.present?
      (total_pennies/100.0).then { |n| n.to_i == n ? n.to_i : n}
    else
      calculate_total
    end
  end

  def total=(new_total)
    self.total_pennies = (new_total*100).round
    new_total
  end

  def score
    total
  end

  def calculate_total
    self.total = (scores || data&.split(" "))&.sum { |v| score_for(v) } || 0
  end

  def score_for(v_index)
    v, partial = v_index.to_s.split(".").map(&:to_i)
    ::Calculator.fibonacci(v+2) * (partial || 1)
  end
end
