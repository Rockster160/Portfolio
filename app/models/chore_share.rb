# == Schema Information
#
# Table name: chore_shares
#
#  id                  :bigint           not null, primary key
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  shared_with_user_id :bigint           not null
#  user_id             :bigint           not null
#
# A ChoreShare row joins two users into the same chore household. The
# bond is bidirectional (one row covers both directions) and transitive
# (A↔B + B↔C ⇒ A, B, C all share one household). A user only ever sees
# one household — there is no permission tier; every member is a full
# editor of every chore in the household.
class ChoreShare < ApplicationRecord
  belongs_to :user
  belongs_to :shared_with_user, class_name: "User"

  validates :shared_with_user_id, uniqueness: { scope: :user_id }
  validate :not_self

  private

  def not_self
    errors.add(:shared_with_user_id, "cannot be the same as the owner") if user_id == shared_with_user_id
  end
end
