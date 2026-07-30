# == Schema Information
#
# Table name: byte_conversations
#
#  id                :bigint           not null, primary key
#  archived          :boolean          default(FALSE), not null
#  buddy_expression  :string           default("neutral"), not null
#  buddy_memories    :text
#  buddy_sleep_until :datetime
#  buddy_theme       :string           default("byte"), not null
#  last_message_at   :datetime
#  metadata          :jsonb            not null
#  mode              :integer          default("claude"), not null
#  name              :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  user_id           :bigint           not null
#
class ByteConversation < ApplicationRecord
  # Users whose Buddy is Moss by default. The pet theme is now per-conversation,
  # so this only seeds the default at creation — nothing else keys off the id.
  MOSS_USER_IDS = [58_128].freeze

  belongs_to :user

  has_many :byte_messages, dependent: :destroy

  enum :mode, { claude: 0, bash: 1, jarvis: 2, buddy: 3 }

  scope :active,  -> { where(archived: false) }
  scope :ordered, -> { order(Arel.sql("last_message_at DESC NULLS LAST, id DESC")) }

  # Threads the buddy:eval rake task writes into. Visible in the list on purpose
  # — reading the back-and-forth is half the point of running an eval — but
  # never the DEFAULT, since an eval run leaves the eval thread with the newest
  # last_message_at and opening the app into 25 canned scenarios isn't what
  # anyone wants. (The harness only runs locally, so this is a papercut rather
  # than anything reaching real traffic.)
  scope :evals, -> { where("metadata->>'eval' = 'true'") }
  scope :real,  -> { where("metadata->>'eval' IS DISTINCT FROM 'true'") }

  def eval?
    metadata.is_a?(Hash) && metadata["eval"].to_s == "true"
  end

  # A new Buddy thread inherits its owner's default pet; the theme then lives on
  # the row and can diverge per conversation. Only buddy convos carry a pet.
  before_create { self.buddy_theme = self.class.default_theme_for(user) if buddy? }

  # Single source of truth for which pet a user's new Buddy threads spin up as.
  def self.default_theme_for(user)
    MOSS_USER_IDS.include?(user&.id) ? "moss" : "byte"
  end

  # Return the user's default conversation, creating one on first access.
  # Fallback used when a message arrives without an explicit conversation
  # (legacy webhook payloads, misconfigured CLI, etc.).
  def self.default_for(user)
    user.byte_conversations.active.real.ordered.first ||
      user.byte_conversations.create!(name: :Byte, mode: :claude)
  end

  # Display name for the pet on a Buddy thread ("Moss"/"Byte"), from this
  # conversation's own theme.
  def buddy_name
    buddy_theme.to_s == "moss" ? "Moss" : "Byte"
  end

  def as_wire
    {
      id:               id,
      name:             display_name,
      mode:             mode,
      archived:         archived,
      last_message_at:  last_message_at&.iso8601(3),
      created_at:       created_at.iso8601(3),
      metadata:         metadata,
      buddy_theme:      buddy_theme,
      buddy_expression: buddy_expression,
    }
  end

  def display_name
    name.presence || default_display_name
  end

  def touch_activity(time=Time.current)
    return if last_message_at && last_message_at >= time

    update_columns(last_message_at: time, updated_at: time)
  end

  private

  def default_display_name
    case mode.to_sym
    when :bash   then "Terminal"
    when :jarvis then "Jarvis"
    when :buddy  then buddy_name
    else "Byte"
    end
  end
end
