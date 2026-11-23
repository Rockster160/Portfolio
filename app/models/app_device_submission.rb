# == Schema Information
#
# Table name: app_device_submissions
#
#  id            :bigint           not null, primary key
#  data          :jsonb            not null
#  error         :text
#  key           :text
#  kind          :text             not null
#  pressed_at    :datetime
#  processed_at  :datetime
#  response      :text
#  source        :text
#  status        :text             default("received"), not null
#  text          :text
#  uuid          :text             not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  app_device_id :bigint           not null
#  message_id    :bigint
#  user_id       :bigint           not null
#
class AppDeviceSubmission < ApplicationRecord
  KINDS = [:command, :buddy, :trigger, :task, :routine, :list_toggle, :answer].freeze

  belongs_to :app_device
  belongs_to :user

  validates :uuid, presence: true, uniqueness: true
  validates :kind, inclusion: { in: KINDS.map(&:to_s) }

  # The reply to a Buddy message lands asynchronously, so it is looked up on read
  # instead of being written back here by the turn.
  def reply_text
    return response if response.present?
    return unless kind == "buddy" && message_id.present?

    reply = ByteMessage.where(direction: :inbound, state: :delivered).where(
      "metadata->>'in_reply_to' = ?", message_id.to_s
    ).order(:id).last
    return if reply.nil?

    update_columns(response: reply.body) # rubocop:disable Rails/SkipsModelValidations
    reply.body
  end

  def serialize(duplicate: false)
    message = message_id.present? ? ByteMessage.find_by(id: message_id) : nil
    {
      id:              uuid,
      status:          status,
      duplicate:       duplicate,
      response:        reply_text,
      message_id:      message_id,
      conversation_id: message&.byte_conversation_id,
      error:           error,
      data:            data.presence,
    }.compact
  end
end
