# == Schema Information
#
# Table name: user_push_subscriptions
#
#  id            :integer          not null, primary key
#  auth          :string
#  channel       :string           default("jarvis"), not null
#  endpoint      :string
#  p256dh        :string
#  registered_at :datetime
#  sub_auth      :string
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  user_id       :integer
#

# deprecated: sub_auth
class UserPushSubscription < ApplicationRecord
  CHANNELS = [:jarvis, :whisper].freeze

  belongs_to :user

  validates :channel, inclusion: { in: CHANNELS.map(&:to_s) }

  scope :for_channel, ->(channel) { where(channel: channel) }
  scope :default_channel, -> { for_channel(:jarvis) }
  scope :whisper, -> { for_channel(:whisper) }

  # before_save :set_sub_auth

  def pushable?
    endpoint.present? && p256dh.present? && auth.present?
  end

  # def set_sub_auth
  #   return if sub_auth.present?
  #
  #   self.sub_auth = loop do
  #     token = SecureRandom.hex(10)
  #     break token unless self.class.where(sub_auth: token).any?
  #   end
  # end
end
