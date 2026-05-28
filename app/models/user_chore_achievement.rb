# == Schema Information
#
# Table name: user_chore_achievements
#
#  id                   :bigint           not null, primary key
#  awarded_pebbles      :integer          default(0), not null
#  earned_at            :datetime         not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  chore_achievement_id :bigint           not null
#  chore_completion_id  :bigint
#  user_id              :bigint           not null
#
class UserChoreAchievement < ApplicationRecord
  belongs_to :user
  belongs_to :chore_achievement
  belongs_to :chore_completion, optional: true

  validates :user_id, uniqueness: { scope: :chore_achievement_id }
end
