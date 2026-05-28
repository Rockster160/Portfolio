# == Schema Information
#
# Table name: chore_hot_picks
#
#  id         :bigint           not null, primary key
#  day_key    :date             not null
#  multiplier :float            default(2.0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  chore_id   :bigint           not null
#
class ChoreHotPick < ApplicationRecord
  belongs_to :chore

  scope :for_day, ->(day) { where(day_key: day) }

  def self.lookup_for(day)
    for_day(day).each_with_object({}) { |hp, h| h[hp.chore_id] = hp.multiplier }
  end
end
