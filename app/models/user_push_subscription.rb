# == Schema Information
#
# Table name: user_push_subscriptions
#
#  id            :integer          not null, primary key
#  auth          :string
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
  belongs_to :user

  # before_save :set_sub_auth

  def pushable?
    endpoint.present? && p256dh.present? && auth.present?
  end

  private

  # def set_sub_auth
  #   return if sub_auth.present?
  #
  #   self.sub_auth = loop do
  #     token = SecureRandom.hex(10)
  #     break token unless self.class.where(sub_auth: token).any?
  #   end
  # end
end
