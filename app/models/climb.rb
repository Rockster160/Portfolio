# == Schema Information
#
# Table name: climbs
#
#  id            :bigint           not null, primary key
#  data          :text
#  scores        :jsonb
#  timestamp     :datetime
#  total_pennies :integer
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  user_id       :bigint
#
class Climb < ApplicationRecord
  belongs_to :user

  scope :not_empty, -> { where("scores IS NOT NULL AND jsonb_array_length(scores) > 0") }

  def self.recent_avg
    order(timestamp: :desc).limit(5).where.not(total_pennies: nil).pluck(:total_pennies).then { |a|
      a.shift
      ((a.any? ? a.sum.to_f / a.length : 0)/100.0).round(2)
    }
  end

  def self.alltime_avg
    (average(:total_pennies).to_f/100.0).round(2)
  end

  def self.best
    all.max_by(&:total_pennies)
  end

  def add(val)
    self.scores ||= []
    self.scores << val.to_f
    calculate_total
    save!
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
    ::Calculator.fibonacci(v+2) * (partial && partial > 0 ? "0.#{partial.to_i}".to_f : 1)
  end
end
