class DeviceLoginToken < ApplicationRecord
  TTL          = 5.minutes
  CODE_LENGTH  = 6
  MAX_ATTEMPTS = 5

  belongs_to :user

  before_validation :assign_token, :assign_code, :assign_expiry, on: :create
  validates :token, presence: true, uniqueness: true
  validates :code, presence: true

  scope :live, -> {
    where(used_at: nil).where(attempts: ...MAX_ATTEMPTS).where(expires_at: Time.current..)
  }

  # One live credential per user at a time. Issuing a new one retires the
  # previous, so a code left up on some other screen stops working the moment
  # its owner asks for a replacement.
  def self.issue!(user)
    where(user: user).delete_all
    create!(user: user)
  end

  # The QR link. Redeeming it is what signs the scanning device in.
  def self.claim_token(token)
    return if token.blank?

    live.find_by(token: token)&.tap(&:consume!)&.user
  end

  # The numeric code, typed into the password field on the other device. A
  # wrong guess spends part of the token's attempt budget instead of leaving
  # a million tries open for the length of the window.
  def self.claim_code(user, code)
    digits = code.to_s.gsub(/\D/, "")
    return if digits.length != CODE_LENGTH

    record = live.find_by(user: user)
    return if record.nil?

    unless ActiveSupport::SecurityUtils.secure_compare(record.code, digits)
      # Atomic UPDATE — parallel guesses each have to pay for themselves.
      record.increment!(:attempts) # rubocop:disable Rails/SkipsModelValidations
      return
    end

    record.consume!
    record.user
  end

  def used?    = used_at.present?
  def expired? = expires_at <= Time.current
  def burned?  = attempts >= MAX_ATTEMPTS
  def live?    = !used? && !expired? && !burned?

  def seconds_remaining = [(expires_at - Time.current).ceil, 0].max
  def formatted_code    = code.scan(/\d{3}/).join(" ")

  def consume!
    update!(used_at: Time.current)
  end

  private

  def assign_token
    self.token ||= loop {
      candidate = SecureRandom.urlsafe_base64(24)
      break candidate unless DeviceLoginToken.exists?(token: candidate)
    }
  end

  def assign_code
    self.code ||= format("%0#{CODE_LENGTH}d", SecureRandom.random_number(10**CODE_LENGTH))
  end

  def assign_expiry
    self.expires_at ||= TTL.from_now
  end
end
