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
#  last_read_at      :datetime
#  metadata          :jsonb            not null
#  mode              :integer          default("claude"), not null
#  name              :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  user_id           :bigint           not null
#
class ByteConversation < ApplicationRecord
  # Users whose new Buddy threads spin up as a non-default pet. The pet theme is
  # now per-conversation, so these only seed the default at creation — nothing
  # else keys off the id. Everything a theme MEANS (name, voice, icon, colour)
  # lives in Buddy::Themes.
  MOSS_USER_IDS = [58_128].freeze  # Chelsea
  SUKI_USER_IDS = [4].freeze       # Eve

  belongs_to :user

  has_many :byte_messages, dependent: :destroy

  # `cursor` runs `cursor-agent` on the Mac the way `claude` runs `claude -p`:
  # same handoff, same streaming, its own session id in metadata. Purely
  # additive — nothing branches on the full set, and default_display_name falls
  # through for anything it doesn't recognise.
  enum :mode, { claude: 0, bash: 1, jarvis: 2, buddy: 3, cursor: 4 }

  # Modes that run on the Mac and therefore have a working directory. Buddy
  # runs entirely in Rails and Jarvis has no filesystem, so a cwd on either is a
  # value nothing would ever read.
  MAC_MODES = %w[claude bash cursor].freeze

  def mac?
    MAC_MODES.include?(mode.to_s)
  end

  def cwd
    metadata.to_h["cwd"].presence
  end

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

  # The thread the wall tablet opens on. /kiosk has no drawer and no composer,
  # so pinning the thread is the only way to say which companion lives out
  # there — everything else about that screen (the character, the name, the
  # palette, the persona it answers in) follows from the thread's own theme.
  scope :kiosk, -> { where("metadata->>'kiosk' = 'true'") }

  # Everything that ISN'T the wall. The complement matters more than the scope
  # itself: a tablet on a table is used constantly and by whoever walks past,
  # so "newest Buddy thread" — how every self-initiated message picks its
  # destination — silently becomes "the wall" the moment somebody taps a
  # routine on it.
  scope :not_kiosk, -> { where("metadata->>'kiosk' IS DISTINCT FROM 'true'") }

  def eval?
    metadata.is_a?(Hash) && metadata["eval"].to_s == "true"
  end

  def kiosk?
    metadata.is_a?(Hash) && metadata["kiosk"].to_s == "true"
  end

  # Move the wall to this thread. Exclusive by construction: "which one is out
  # there" is a single fact, and leaving two pinned would make what the tablet
  # opens on depend on row order.
  def self.pin_kiosk!(conversation)
    transaction {
      conversation.user.byte_conversations.kiosk.where.not(id: conversation.id).find_each { |other|
        other.update!(metadata: other.metadata.except("kiosk"))
      }
      conversation.update!(metadata: conversation.metadata.merge("kiosk" => true))
    }
    conversation
  end

  # Where a message NOBODY ASKED FOR goes: the morning briefing, a reminder
  # firing, a watch tripping, a relay from the other person, a chore's prompt.
  #
  # Their newest live Buddy thread, except the wall tablet and except an eval
  # thread. Both fail the same way and for the same reason — `ordered` means
  # "most recently active", and both of them are active without anyone
  # personally reading them. The wall is a screen in a room: a briefing
  # delivered there is read by whoever happens to be standing in the kitchen,
  # which is not the same as being read by the person it was for.
  #
  # Falls back to the excluded thread when it's the only one, because a
  # briefing on the wall still beats a briefing nowhere. That fallback is safe
  # precisely because the push is suppressed independently — see ByteNotifier —
  # so the worst case is that it shows up silently rather than not at all.
  def self.for_self_initiated(user)
    scope = user.byte_conversations.active.buddy
    scope.not_kiosk.real.ordered.first || scope.ordered.first
  end

  # Set by any caller that let a person CHOOSE the pet — today that's the
  # new-conversation form. Every other caller stays silent and gets the
  # account's default seeded below.
  #
  # A flag rather than dirty-tracking, because `buddy_theme` carries a column
  # default of "byte": someone on a Suki account deliberately picking Byte
  # assigns a value identical to the default, so `buddy_theme_changed?` is
  # false and their choice is indistinguishable from not having made one.
  attr_accessor :theme_chosen

  # A new Buddy thread inherits its owner's default pet; the theme then lives on
  # the row and can diverge per conversation. Only buddy convos carry a pet.
  before_create { self.buddy_theme = self.class.default_theme_for(user) if buddy? && !theme_chosen }

  # Single source of truth for which pet a user's new Buddy threads spin up as.
  def self.default_theme_for(user)
    case user&.id
    when *MOSS_USER_IDS then :moss
    when *SUKI_USER_IDS then :suki
    else :byte
    end
  end

  # Display name ("Byte"/"Moss"/"Suki") for a theme string.
  def self.display_name_for(theme)
    Buddy::Themes.name_for(theme)
  end

  # Return the user's default conversation, creating one on first access.
  # Fallback used when a message arrives without an explicit conversation
  # (legacy webhook payloads, misconfigured CLI, etc.).
  def self.default_for(user)
    user.byte_conversations.active.real.ordered.first ||
      user.byte_conversations.create!(name: :Byte, mode: :claude)
  end

  # Display name for the pet on a Buddy thread ("Byte"/"Moss"/"Suki"), from this
  # conversation's own theme.
  def buddy_name
    self.class.display_name_for(buddy_theme)
  end

  # Messages that landed after the last time this thread was looked at.
  #
  # Server-side because it's the only place that can answer it. The count used
  # to live in the page, which meant a reload wiped it and — worse — anything
  # that arrived while the app was closed was never counted at all, since
  # counting only happened in response to a live broadcast.
  def unread_count
    return 0 if last_read_at.nil?

    byte_messages.readable.where("byte_messages.created_at > ?", last_read_at).count
  end

  # Opening a thread IS reading it.
  #
  # `update_columns` rather than `update!`: this fires on every conversation
  # switch, it touches one column nothing validates, and going through
  # callbacks would bump `updated_at` and shuffle the drawer ordering on a
  # plain read.
  def mark_read!(at=Time.current)
    return if last_read_at && last_read_at >= at

    update_columns(last_read_at: at)
  end

  # Everything waiting for this person, across every thread they can see. What
  # the iOS home-screen badge shows, and what rides on the push so the badge is
  # still right when the app has been closed for hours.
  #
  # The wall is left out. A number on the phone's home screen says "something
  # is waiting for you", and a routine somebody tapped on the tablet in the
  # kitchen is not waiting for anyone — it already happened, in front of them.
  # The per-thread count in the drawer still shows it, so nothing is hidden;
  # it just doesn't follow anyone out of the house.
  def self.unread_total_for(user)
    where(user_id: user.id, archived: false).not_kiosk.sum(&:unread_count)
  end

  def as_wire
    {
      id:               id,
      name:             display_name,
      mode:             mode,
      archived:         archived,
      unread_count:     unread_count,
      last_message_at:  last_message_at&.iso8601(3),
      created_at:       created_at.iso8601(3),
      metadata:         metadata,
      buddy_theme:      buddy_theme,
      # The pet's name travels with the thread so the client never has to carry
      # its own copy of the theme table — switching threads repaints the title
      # and the sleeping chip off this.
      buddy_name:       buddy_name,
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
