# == Schema Information
#
# Table name: chore_dailies
#
#  id         :bigint           not null, primary key
#  sort_order :integer          default(0), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  chore_id   :bigint           not null
#  user_id    :bigint           not null
#
class ChoreDaily < ApplicationRecord
  belongs_to :user
  belongs_to :chore

  validates :chore_id, uniqueness: { scope: :user_id }

  scope :for_user, ->(user) { where(user_id: user.id).order(:sort_order, :id) }
end
