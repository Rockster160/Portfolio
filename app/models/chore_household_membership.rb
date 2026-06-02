# == Schema Information
#
# Table name: chore_household_memberships
#
#  id                 :bigint           not null, primary key
#  role               :integer          default("member"), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  chore_household_id :bigint           not null
#  user_id            :bigint           not null
#
class ChoreHouseholdMembership < ApplicationRecord
  ROLES = { member: 0, manager: 1 }.freeze

  enum :role, ROLES, default: :member

  belongs_to :chore_household
  belongs_to :user

  validates :user_id, uniqueness: true

  # `users.chore_household_id` is a denormalized cache of this row so
  # chore endpoints can read the household without a join; the
  # membership row is the source of truth.
  after_commit :sync_user_cache,  on: [:create, :update]
  after_commit :clear_user_cache, on: :destroy

  private

  def sync_user_cache
    return if user.chore_household_id == chore_household_id

    user.update_column(:chore_household_id, chore_household_id)
  end

  def clear_user_cache
    return if user.nil?
    return if user.chore_household_id != chore_household_id

    user.update_column(:chore_household_id, nil)
  end
end
