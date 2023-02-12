# == Schema Information
#
# Table name: climbs
#
#  id         :bigint           not null, primary key
#  data       :text
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint
#
class Climb < ApplicationRecord
  belongs_to :user

  SCORE_MAP = { "0": 0.5 }

  def score
    data.split(" ").sum { |v| SCORE_MAP[v] || v.to_f }
  end
end
