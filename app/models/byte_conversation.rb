# == Schema Information
#
# Table name: byte_conversations
#
#  id              :bigint           not null, primary key
#  archived        :boolean          default(FALSE), not null
#  last_message_at :datetime
#  metadata        :jsonb            not null
#  mode            :integer          default("claude"), not null
#  name            :string
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  user_id         :bigint           not null
#
class ByteConversation < ApplicationRecord
  belongs_to :user

  has_many :byte_messages, dependent: :destroy

  enum :mode, { claude: 0, bash: 1, jarvis: 2 }

  scope :active,  -> { where(archived: false) }
  scope :ordered, -> { order(Arel.sql("last_message_at DESC NULLS LAST, id DESC")) }

  # Return the user's default conversation, creating one on first access.
  # Fallback used when a message arrives without an explicit conversation
  # (legacy webhook payloads, misconfigured CLI, etc.).
  def self.default_for(user)
    user.byte_conversations.active.ordered.first ||
      user.byte_conversations.create!(name: :Byte, mode: :claude)
  end

  def as_wire
    {
      id:              id,
      name:            display_name,
      mode:            mode,
      archived:        archived,
      last_message_at: last_message_at&.iso8601(3),
      created_at:      created_at.iso8601(3),
      metadata:        metadata,
    }
  end

  def display_name
    name.presence || default_display_name
  end

  def touch_activity(time = Time.current)
    return if last_message_at && last_message_at >= time

    update_columns(last_message_at: time, updated_at: time)
  end

  private def default_display_name
    case mode.to_sym
    when :bash   then "Terminal"
    when :jarvis then "Jarvis"
    else "Byte"
    end
  end
end
