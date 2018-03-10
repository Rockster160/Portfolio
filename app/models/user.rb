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
#  role             :integer          default("standard")
#

class User < ApplicationRecord
  attr_accessor :should_require_current_password, :current_password

  has_many :user_lists, dependent: :destroy
  has_many :lists, through: :user_lists
  has_one :avatar

  has_secure_password validations: false

  validates_uniqueness_of :phone, allow_nil: true
  validate :proper_fields_present?

  scope :by_username, ->(username) { where("lower(username) = ?", username.to_s.downcase) }

  enum role: {
    standard: 0,
    admin:    10
  }

  def self.auth_from_basic(basic_auth)
    username, password = basic_auth.split(":", 2)
    attempt_login(username, password)
  end

  def self.attempt_login(username, password)
    user = by_username(username).first

    if user.present? && user.authenticate(password)
      user
    else
      false
    end
  end

  def self.find_or_create_by_filtered_params(raw_params)
    return User.new if raw_params.blank?
    user_scope = User.all
    user_scope = user_scope.where("lower(username) = ?", raw_params[:username].to_s.downcase.squish) if raw_params[:username].present?
    user_scope = user_scope.where(phone: raw_params[:phone].gsub(/[^0-9]/, "").last(10)) if raw_params[:phone].present?
    user_scope = user_scope.where(raw_params.except(:username, :phone))
    user_scope.first || User.new(raw_params)
  end

  def see!
    # last logged in at NOW
  end

  def update_with_password(new_attrs)
    should_require_current_password = true
    update(new_attrs)
  end

  def update_avatar(character)
    (avatar || build_avatar).update_by_builder(character)
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

  def ordered_lists
    lists.includes(user_lists: :list).where(user_lists: { user_id: id }).order("user_lists.sort_order")
  end

  def invite!(list)
    user_lists.create(list_id: list.id)
    return unless Rails.env.production?
    return unless phone.present?

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

  def proper_fields_present?
    if invited?
      if phone.blank? && username.blank?
        errors.add(:base, "User must have a Username or Phone Number")
      end
    else
      if new_record?
        password_length = @password.try(:length).to_i
        if password_length < 8 || password_length > 32
          errors.add(:password, "must be at least 8 and no more than 32 characters.")
        end
      end
      valid_presence?(:password_digest, :password)
      valid_presence?(:username)
      confirmation_matches_password
      username_constraints
      format_phone
      correct_current_password
    end
  end

  def valid_presence?(sym, error_sym=nil)
    error_sym ||= sym
    unless send(sym).present?
      errors.add(error_sym, "must be present.")
    end
  end

  def format_phone
    return unless phone.present?
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
