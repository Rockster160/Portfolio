# == Schema Information
#
# Table name: chore_streaks
#
#  id                 :bigint           not null, primary key
#  current_streak     :integer          default(0), not null
#  last_completed_day :date
#  longest_streak     :integer          default(0), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  chore_id           :bigint           not null
#  user_id            :bigint           not null
#
class ChoreStreak < ApplicationRecord
  belongs_to :user
  belongs_to :chore
end
