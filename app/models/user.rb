# == Schema Information
#
# Table name: users
#
#  id              :integer          not null, primary key
#  username        :string
#  password_digest :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#

class User < ApplicationRecord

  has_many :user_lists
  has_many :lists, through: :user_lists

  has_secure_password
  validates :password, length: { minimum: 8, maximum: 32 }, on: :create
  validates_presence_of :username
  validate :username_constraints

  scope :by_username, ->(username) { where("lower(username) = ?", username.to_s.downcase) }

  def self.attempt_login(username, password)
    user = by_username(username).first

    if user.present? && user.authenticate(password)
      user
    else
      false
    end
  end

  def owns_list?(list)
    !!user_lists.where(list_id: list.try(:id)).try(:is_owner)
  end

  private

  def username_constraints
    self.username = username.to_s.squish

    if User.by_username(username).where.not(id: self.id).any?
      errors.add(:base, "Sorry! That username has already been taken.")
      return
    end
    if username.length < 3 || username.length > 20
      errors.add(:username, "must be between 3 and 20 charactes in length.")
    end
    unless (username =~ /[^a-zA-Z0-9]/).nil?
      errors.add(:username, "can only contain alphanumeric characters.")
    end
  end

end
