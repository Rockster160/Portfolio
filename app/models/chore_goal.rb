# == Schema Information
#
# Table name: chore_goals
#
#  id           :bigint           not null, primary key
#  achieved_at  :datetime
#  archived_at  :datetime
#  cost_pebbles :integer          default(0), not null
#  image_url    :text
#  link_url     :text
#  name         :string           not null
#  sort_order   :integer
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
class ChoreGoal < ApplicationRecord
  include Orderable

  orderable_by(sort_order: :asc)
  orderable_scope ->(goal) { ChoreGoal.where(user_id: goal.user_id) }

  belongs_to :user

  validates :name, presence: true
  validates :cost_pebbles, numericality: { greater_than_or_equal_to: 0 }

  scope :user_goals, ->(user_id = nil) { user_id ? where(user_id: user_id) : all }
  scope :active, -> { where(archived_at: nil) }
  scope :outstanding, -> { active.where(achieved_at: nil) }
end
