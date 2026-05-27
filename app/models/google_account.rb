# == Schema Information
#
# Table name: google_accounts
#
#  id                  :bigint           not null, primary key
#  access_token        :text
#  email               :string           not null
#  id_token            :text
#  reauth_required_at  :datetime
#  refresh_token       :text
#  tokens_refreshed_at :datetime
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  user_id             :bigint           not null
#
# A Google account the user has authorized us against. Each row owns its
# own OAuth credentials (access_token + refresh_token); a user may have
# many. Each AgendaConnection links an Agenda to one of these so the sync
# layer knows whose tokens to use.
class GoogleAccount < ApplicationRecord
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
