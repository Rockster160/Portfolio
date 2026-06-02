# == Schema Information
#
# Table name: chore_households
#
#  id            :bigint           not null, primary key
#  name          :text             default(""), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  owner_user_id :bigint           not null
#
# Permissions:
#   * owner   — household-level admin (transfer ownership, delete).
#               Always counts as :manager for chore-edit checks.
#   * manager — full read+write on chores, streak bonuses, history.
#   * member  — read+complete only. Can create personal goals but
#               cannot set `awarded_pebbles` (that's a manager call).
class ChoreHousehold < ApplicationRecord
  belongs_to :owner_user, class_name: "User"

  has_many :memberships,
    class_name: "ChoreHouseholdMembership",
    dependent: :destroy
  has_many :members, through: :memberships, source: :user
  has_many :chores, dependent: :destroy
  # Rails' default inflector mangles "bonuses" → "bonuse"; pin the class.
  has_many :chore_streak_bonuses, class_name: "ChoreStreakBonus", dependent: :destroy

  validates :name, presence: true

  after_create :ensure_owner_membership

  def member_user_ids
    memberships.pluck(:user_id)
  end

  def manager?(user)
    return false if user.nil?
    return true if user.id == owner_user_id

    memberships.where(user_id: user.id, role: :manager).exists?
  end

  def member?(user)
    return false if user.nil?

    memberships.where(user_id: user.id).exists?
  end

  def owner?(user)
    user.present? && user.id == owner_user_id
  end

  private

  def ensure_owner_membership
    return if memberships.where(user_id: owner_user_id).exists?

    memberships.create!(user_id: owner_user_id, role: :manager)
  end
end
