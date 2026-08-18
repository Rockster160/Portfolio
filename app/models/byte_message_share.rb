# == Schema Information
#
# Table name: byte_message_shares
#
#  id                   :bigint           not null, primary key
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint           not null
#  byte_message_id      :bigint           not null
#  user_id              :bigint           not null
#
class ByteMessageShare < ApplicationRecord
  # One message, shown in a second person's thread, WITHOUT a second copy of it.
  #
  # The doorbell frame is one event. It was previously delivered by writing the
  # row twice — once per thread — and then keeping the pair in step by hand:
  # CompanionRelay#bridge! set `metadata["relay_twin"]` on both, and
  # Buddy::Reactions wrote every tapback to both rows so one person's 👍 would
  # show up for the other. Two rows that must never disagree is a maintenance
  # tax paid forever, and everything added later (edits, attachments, action
  # state) has to remember to pay it.
  #
  # So the message keeps ONE home — the conversation that produced it, which is
  # also who authored it and where its attachments hang — and a share points a
  # second conversation at it. Reactions, files and metadata are then shared by
  # construction rather than by mirroring: there is only one row to react to.
  belongs_to :byte_message
  belongs_to :byte_conversation
  # The recipient. Derivable from the conversation, but denormalized because
  # unread counting and "what's shared with me" both scope by person, and both
  # would otherwise join through conversations on every read.
  belongs_to :user

  validates :byte_message_id, uniqueness: { scope: :byte_conversation_id }

  validate :not_its_own_home

  scope :for_conversation, ->(conversation) { where(byte_conversation: conversation) }

  # Share a message into a conversation. Idempotent: re-delivering the same
  # frame is a no-op rather than a duplicate row or a raise, because the callers
  # are notification paths that can legitimately fire twice.
  def self.share!(message, conversation)
    return nil if message.byte_conversation_id == conversation.id

    share = find_or_create_by!(byte_message: message, byte_conversation: conversation) { |s|
      s.user = conversation.user
    }
    share.broadcast!
    share
  end

  # Show a message to one other person, in their own Buddy thread.
  #
  # ONE person rather than the household: a doorbell frame is for whoever
  # actually wants the front door, and fanning it at everyone under the roof
  # turns a useful ping into one people learn to swipe away.
  #
  # Pushed as well as broadcast: the broadcast reaches a screen that's already
  # open, the push reaches a pocket, and a doorbell is mostly the second case.
  # Returns nil when there's nowhere to put it, so callers can stay quiet
  # rather than claim a delivery.
  def self.share_with!(message, to:)
    return nil if to.nil?

    conversation = ByteConversation.for_self_initiated(to) || ByteConversation.default_for(to)
    return nil if conversation.nil? || !conversation.buddy?

    share = share!(message, conversation)
    ByteNotifier.notify(to, message) if share
    share
  end

  # Put it on the recipient's screen. Addressed to THEIR conversation, because
  # the client routes by the thread a frame names and the row's own id names a
  # thread they can't see.
  def broadcast!
    MonitorChannel.broadcast_to(user, {
      id:      :byte,
      channel: :byte,
      data:    { kind: :message, message: byte_message.as_wire(conversation_id: byte_conversation_id) },
    })
  rescue StandardError => e
    Rails.logger.warn("[ByteMessageShare] broadcast failed for #{id}: #{e.class}: #{e.message}")
  end

  private

  # A message is already in its home conversation; a share saying so would make
  # it appear twice in the one thread that definitely has it.
  def not_its_own_home
    return if byte_message.nil? || byte_conversation_id.nil?
    return unless byte_message.byte_conversation_id == byte_conversation_id

    errors.add(:byte_conversation, "already owns this message")
  end
end
