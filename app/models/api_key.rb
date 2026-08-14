# == Schema Information
#
# Table name: api_keys
#
#  id           :bigint           not null, primary key
#  enabled      :boolean          default(TRUE)
#  key          :text
#  last_used_at :datetime
#  name         :text
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint
#

# Should DEFINITELY have a uniqueness constraint on key
class ApiKey < ApplicationRecord
  belongs_to :user

  after_initialize { self.key ||= SecureRandom.hex.upcase }

  scope :enabled, -> { where(enabled: true) }

  # The one lookup every door goes through: AuthHelper (which is every HTTP
  # request carrying an Authorization header), the cable connection, and the
  # byte webhooks.
  #
  # It exists because `enabled` was decorative. Disabling a key wrote the column
  # and NOTHING read it back — three separate `find_by(key:)` calls, none of
  # them filtered — so a key someone had deliberately turned off still opened
  # /jil/trigger, still opened the websocket, and still posted to Byte. The one
  # action a person takes when a key has leaked did nothing at all.
  #
  # Stamps `last_used_at` here rather than at the call sites, because all three
  # of them did it and one forgetting to is how a live key starts looking stale.
  def self.authenticate(raw_key)
    return nil if raw_key.blank?

    enabled.find_by(key: raw_key)&.tap(&:use!)
  end

  def disabled? = !enabled?

  def use!(time=Time.current)
    update(last_used_at: time)
  end
end
