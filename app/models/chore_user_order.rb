# == Schema Information
#
# Table name: chore_user_orders
#
#  id         :bigint           not null, primary key
#  sort_order :integer          not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  chore_id   :bigint           not null
#  user_id    :bigint           not null
#
class ChoreUserOrder < ApplicationRecord
  belongs_to :user
  belongs_to :chore

  validates :user_id, uniqueness: { scope: :chore_id }
end
