# == Schema Information
#
# Table name: google_accounts
#
#  id                  :bigint           not null, primary key
#  access_token        :text
#  disconnected_at     :datetime
#  email               :string           not null
#  id_token            :text
#  reauth_required_at  :datetime
#  refresh_token       :text
#  tokens_refreshed_at :datetime
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  user_id             :bigint           not null
#
class GoogleAccount < ApplicationRecord
  # Tokens get encrypted at rest once the encryption ENV vars are set —
  # see config/initializers/active_record_encryption.rb. Until then this
  # is a no-op (encryption config is nil; values stay plain text).
  # `support_unencrypted_data = true` in the initializer lets reads work
  # transparently across both states during the transition.
  if ENV["PORTFOLIO_AR_ENCRYPTION_PRIMARY_KEY"].present?
    encrypts :access_token
    encrypts :refresh_token
    encrypts :id_token
  end

  belongs_to :user
  has_many :agendas, dependent: :destroy

  validates :email, presence: true, uniqueness: { scope: :user_id }

  before_validation :normalize_email

  def needs_reauth?
    reauth_required_at.present?
  end

  def mark_reauth_required!(at: ::Time.current)
    update!(reauth_required_at: at)
  end

  def clear_reauth_required!
    return if reauth_required_at.blank?

    update!(reauth_required_at: nil)
  end

  def api
    ::Oauth::GoogleApi.for_account(self)
  end

  private

  def normalize_email
    self.email = email.to_s.strip.downcase.presence
  end
end
