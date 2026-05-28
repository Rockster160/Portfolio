# == Schema Information
#
# Table name: chore_shares
#
#  id                  :bigint           not null, primary key
#  permission          :integer          default("editor"), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  shared_with_user_id :bigint           not null
#  user_id             :bigint           not null
#
class ChoreShare < ApplicationRecord
  belongs_to :user
  belongs_to :shared_with_user, class_name: "User"

  enum :permission, { viewer: 0, editor: 1, owner: 2 }, default: :editor

  validates :shared_with_user_id, uniqueness: { scope: :user_id }
  validate :not_self

  private

  def not_self
    errors.add(:shared_with_user_id, "cannot be the same as the owner") if user_id == shared_with_user_id
  end
end
