# == Schema Information
#
# Table name: byte_messages
#
#  id                   :bigint           not null, primary key
#  body                 :text
#  delivered_at         :datetime
#  direction            :integer          default("outbound"), not null
#  external_ref         :string
#  metadata             :jsonb            not null
#  state                :integer          default("pending"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint           not null
#  user_id              :bigint           not null
#
class ByteMessage < ApplicationRecord
  # A message in the Byte chat surface.
  # `direction` distinguishes user→server (outbound) from server→user (inbound).
  # `state` covers the lifecycle including :streaming for AI-style
  # progressive-write updates and :delivered for finalised inbound.
  # `metadata` is the open-ended jsonb envelope; `files` carries attachments
  # via ActiveStorage.
  belongs_to :user
  belongs_to :byte_conversation

  has_many_attached :files

  enum :direction, { outbound: 0, inbound: 1 }
  # NOTE: never reassign existing integers — enum order is persisted.
  enum :state,     { pending: 0, sent: 1, delivered: 2, failed: 3, streaming: 4 }

  scope :recent,        -> { order(created_at: :desc) }
  scope :chronological, -> { order(created_at: :asc) }

  # Fallback so callers that create messages via `user.byte_messages.create!`
  # (without an explicit conversation) still work — attaches to the user's
  # default conversation. Production callers always pass one explicitly.
  before_validation :assign_default_conversation, on: :create

  after_commit :bump_conversation_activity, on: [:create, :update]

  def as_wire
    {
      id:              id,
      conversation_id: byte_conversation_id,
      direction:       direction,
      state:           state,
      body:            body,
      external_ref:    external_ref,
      metadata:        metadata,
      attachments:     attachments_wire,
      created_at:      created_at.iso8601(3),
      delivered_at:    delivered_at&.iso8601(3),
    }
  end

  private

  def assign_default_conversation
    return if byte_conversation_id.present? || byte_conversation.present?
    return if user.nil?

    self.byte_conversation = ByteConversation.default_for(user)
  end

  def bump_conversation_activity
    byte_conversation&.touch_activity(created_at)
  end

  def attachments_wire
    return [] unless files.attached?

    files.map { |f|
      {
        id:           f.id,
        filename:     f.filename.to_s,
        content_type: f.content_type,
        byte_size:    f.byte_size,
        url:          Rails.application.routes.url_helpers.rails_blob_path(f),
      }
    }
  end
end
