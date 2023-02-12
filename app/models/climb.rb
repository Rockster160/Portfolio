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

  SCORE_MAP = { "0": 0.5 }

  def score
    data.split(" ").sum { |v| score_for(v) }
  end

  def score_for(go)
    SCORE_MAP[go.to_s.to_sym] || go.to_f
  end
end
