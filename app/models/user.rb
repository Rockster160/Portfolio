# == Schema Information
#
# Table name: users
#
#  id               :integer          not null, primary key
#  username         :string
#  password_digest  :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  phone            :string
#  invitation_token :string
#

class User < ApplicationRecord
  attr_accessor :should_require_current_password, :current_password

  has_many :user_lists
  has_many :lists, through: :user_lists

  has_secure_password validations: false
  validates :password, length: { minimum: 8, maximum: 32 }, on: :create, unless: :invited?
  validates_presence_of :password, unless: :invited?, on: :create
  validates_presence_of :username, unless: :invited?
  validate :confirmation_matches_password, unless: :invited?
  validate :username_constraints, unless: :invited?
  validate :formatted_phone
  validate :correct_current_password
  validates_uniqueness_of :phone, allow_nil: true

  scope :by_username, ->(username) { where("lower(username) = ?", username.to_s.downcase) }

  def self.attempt_login(username, password)
    user = by_username(username).first

    if user.present? && user.authenticate(password)
      user
    else
      false
    end
  end

  def update_with_password(new_attrs)
    should_require_current_password = true
    update(new_attrs)
  end

  def owns_list?(list)
    !!user_lists.where(list_id: list.try(:id)).try(:is_owner)
  end

  def assign_invitation_token
    self.invitation_token ||= loop do
      lower_alpha = ('a'..'z').to_a
      upper_alpha = ('A'..'Z').to_a
      numeric = (0..9).to_a
      alpha_num = (lower_alpha + upper_alpha + numeric)
      token = "#{alpha_num.sample(3).join('')}-#{alpha_num.sample(3).join('')}"
      break token unless self.class.where(invitation_token: token).any?
    end
  end

  def invite!(list)
    user_lists.create(list_id: list.id)

    message = "You've been added to the list: \"#{list.name.titleize}\". Click the link below to join:\n"
    if invited?
      message += Rails.application.routes.url_helpers.register_url(invitation_token: invitation_token)
    else
      message += Rails.application.routes.url_helpers.list_url(list.name.parameterize)
    end
    SmsWorker.perform_async(phone, message)
  end

  def invited?
    invitation_token.present?
  end

  private

  def formatted_phone
    stripped_phone = phone.gsub(/[^0-9]/, "").last(10)

    if stripped_phone.length == 10
      self.phone = stripped_phone
    elsif stripped_phone.present?
      errors.add(:phone, "must be a valid, 10 digit number.")
    else
      self.phone = nil
    end
  end

  def correct_current_password
    return unless should_require_current_password
    unless authenticate(current_password)
      errors.add(:current_password, "wasn't right.")
    end
  end

  def confirmation_matches_password
    unless @password == @password_confirmation
      errors.add(:password, "must match confirmation.")
    end
  end

  def username_constraints
    self.username = username.to_s.squish

    if User.by_username(username).where.not(id: self.id).any?
      errors.add(:base, "Sorry! That username has already been taken.")
      return
    end
    if username.length < 3 || username.length > 20
      errors.add(:username, "must be between 3 and 20 characters in length.")
    end
    unless (username =~ /[^a-zA-Z0-9_-]/).nil?
      errors.add(:username, "can only contain alphanumeric characters.")
    end
  end

end
