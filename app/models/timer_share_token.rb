# == Schema Information
#
# Table name: timer_share_tokens
#
#  id            :bigint           not null, primary key
#  access_mode   :integer          default("view_only"), not null
#  expires_at    :datetime
#  hit_count     :integer          default(0), not null
#  revoked_at    :datetime
#  token         :string           not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  timer_id      :bigint
#  timer_page_id :bigint
#  user_id       :bigint           not null
#
class TimerShareToken < ApplicationRecord
  ACCESS_MODES = { view_only: 0, interactive: 1 }.freeze
  enum :access_mode, ACCESS_MODES

  belongs_to :user
  belongs_to :timer,      optional: true
  belongs_to :timer_page, optional: true

  before_validation :assign_token, on: :create
  validates :token, presence: true, uniqueness: true
  validate  :exactly_one_target

  scope :live, -> {
    where(revoked_at: nil).where("expires_at IS NULL OR expires_at > ?", Time.current)
  }

  def revoked? = revoked_at.present?
  def expired? = expires_at.present? && expires_at < Time.current
  def usable?  = !revoked? && !expired?
  def target   = timer || timer_page

  def revoke!
    update!(revoked_at: Time.current)
  end

  private

  def assign_token
    self.token ||= loop {
      candidate = SecureRandom.urlsafe_base64(16)
      break candidate unless TimerShareToken.exists?(token: candidate)
    }
  end

  def exactly_one_target
    set = [timer_id, timer_page_id].count(&:present?)
    errors.add(:base, "must reference exactly one timer or timer_page") unless set == 1
  end
end
