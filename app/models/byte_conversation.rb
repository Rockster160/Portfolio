# == Schema Information
#
# Table name: byte_conversations
#
#  id                  :bigint           not null, primary key
#  archived            :boolean          default(FALSE), not null
#  buddy_compile_after :datetime
#  buddy_compiled_at   :datetime
#  buddy_expression    :string           default("neutral"), not null
#  buddy_memories      :text
#  buddy_sleep_until   :datetime
#  buddy_theme         :string           default("byte"), not null
#  buddy_topic         :text
#  buddy_topic_at      :datetime
#  last_message_at     :datetime
#  last_read_at        :datetime
#  metadata            :jsonb            not null
#  mode                :integer          default("claude"), not null
#  name                :string
#  primary_at          :datetime
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  user_id             :bigint           not null
#
class ByteConversation < ApplicationRecord
  # Users whose new Buddy threads spin up as a non-default pet. The pet theme is
  # now per-conversation, so these only seed the default at creation — nothing
  # else keys off the id. Everything a theme MEANS (name, voice, icon, colour)
  # lives in Buddy::Themes.
  MOSS_USER_IDS = [58_128].freeze  # Chelsea
  SUKI_USER_IDS = [4].freeze       # Eve

  belongs_to :user

  # Messages this thread OWNS. Deliberately unchanged: it is the creation path,
  # the cascade, and the answer to "whose row is this". Reading a thread goes
  # through `visible_messages` instead, which adds what's been shared in.
  has_many :byte_messages, dependent: :destroy

  # Messages shared INTO this thread — one row living in someone else's
  # conversation, shown here too. Destroying the thread drops the shares, never
  # the messages: they belong to whoever produced them.
  has_many :byte_message_shares, dependent: :destroy
  has_many :shared_messages, through: :byte_message_shares, source: :byte_message

  # Everything this thread shows, owned and shared alike, as ONE relation so it
  # still takes `.chronological`, `.where(id: ...before)` and `.exists?` the way
  # the bare association did. Ordering is by the message's own created_at, so
  # sharing something old drops it into the thread where it happened rather than
  # at the bottom — it is the same event, not a new one.
  def visible_messages
    shared = ByteMessageShare.where(byte_conversation_id: id).select(:byte_message_id)
    ByteMessage.where(byte_conversation_id: id).or(ByteMessage.where(id: shared))
  end

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

  # Threads the buddy:eval task writes into. Visible in the list on purpose
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

  # THE thread. Everything nobody asked for lands here — the morning briefing, a
  # reminder firing, a watch tripping, a relay from the other person — rather
  # than in whichever one happens to have been touched most recently.
  #
  # "Most recently active" was never the right answer, only the easy one. It
  # follows the person around: reading a shared thread, tapping a routine, or an
  # automation posting a receipt all move it, so where tomorrow's briefing turns
  # up depends on what you did last night. This is a choice they make once.
  #
  # A COLUMN rather than a metadata key, unlike the kiosk pin next door. That bag
  # is merged from client-supplied params in ByteController#update_conversation,
  # so an invariant kept in it isn't one — an ordinary PATCH could mark three
  # threads at once and walk straight past pin_primary!. The partial unique index
  # behind this column makes two primaries impossible in the DATABASE rather than
  # impossible-if-everybody-uses-the-front-door.
  scope :primary, -> { where.not(primary_at: nil) }

  def eval?
    metadata.is_a?(Hash) && metadata["eval"].to_s == "true"
  end

  def kiosk?
    metadata.is_a?(Hash) && metadata["kiosk"].to_s == "true"
  end

  def primary?
    primary_at.present?
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

  # Make this the primary one. Exclusive by construction, like the kiosk pin and
  # for the same reason: "which thread do I actually read" is a single fact, and
  # leaving two marked would make where a briefing lands depend on row order.
  #
  # There is deliberately no unset. Nothing NOT being primary is not a state
  # anyone wants — self-initiated messages have to go somewhere, so clearing the
  # flag would only hand the choice back to whatever heuristic replaced it.
  # Choosing a different one is how you change your mind.
  # Clear THEN set, in that order and in one transaction: the partial unique
  # index refuses a second primary, so setting first would fail on its own
  # constraint rather than replacing anything.
  def self.pin_primary!(conversation)
    transaction {
      conversation.user.byte_conversations.primary.where.not(id: conversation.id).update_all(primary_at: nil)
      conversation.update!(primary_at: Time.current)
    }
    conversation
  end

  # Which Buddy thread is the primary one, chosen or not.
  #
  # The default is their FIRST buddy thread — oldest id, not newest activity —
  # and that ordering is the whole point: it can't drift. Somebody who never
  # opens this setting gets the same thread forever, which is what makes the
  # marked one a decision rather than a race.
  #
  # The wall tablet and eval threads are out on the way in. Both are "active"
  # without anyone personally reading them: the wall is a screen in a room, so a
  # briefing delivered there is read by whoever is standing in the kitchen, and
  # a `bx rails buddy:eval` run leaves 25 canned scenarios looking like the liveliest
  # thread on the account.
  def self.primary_for(user)
    primary_among(user.byte_conversations.active.buddy.ordered.to_a)
  end

  # The rule itself, over rows that are already in hand.
  #
  # Split out because the answer is wanted in two places with very different
  # costs: `for_self_initiated` has nothing loaded, and the conversations index
  # has the whole list sitting in front of it — asking the database again there
  # is a round trip for data already on the page.
  #
  # Takes the FULL list and filters here rather than expecting a pre-narrowed
  # one, so a caller can't get the eligibility half wrong while getting the
  # ordering half right.
  def self.primary_among(conversations)
    eligible = conversations.select { |c| c.buddy? && !c.archived? && !c.kiosk? && !c.eval? }

    eligible.find(&:primary?) || eligible.min_by(&:id)
  end

  # Where a message NOBODY ASKED FOR goes: the morning briefing, a reminder
  # firing, a watch tripping, a relay from the other person, a chore's prompt.
  #
  # Falls back to a thread `primary_for` excluded when it's the only one there
  # is, because a briefing on the wall still beats a briefing nowhere. That
  # fallback is safe precisely because the push is suppressed independently —
  # see ByteNotifier — so the worst case is that it shows up silently rather
  # than not at all.
  def self.for_self_initiated(user)
    # ONE query, and `ordered` is what makes the fallback free — the rows come
    # back newest-first already, so `.first` is the old "newest live thread"
    # answer with no second round trip.
    all = user.byte_conversations.active.buddy.ordered.to_a

    primary_among(all) || all.first
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

  # Their FIRST buddy thread claims primary, once, here.
  #
  # `primary_among` would answer the same thing without this — an unmarked
  # account resolves to its oldest thread anyway — but writing it down is what
  # makes the answer a single indexed lookup instead of a scan-and-sort, and it
  # makes `as_wire[:primary]` truthful about the thread that actually holds it.
  # Set at the one moment it can change, rather than re-derived on every read.
  after_create :claim_primary_if_first

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
      # The EXPLICIT flag only. Whether an unmarked thread is primary by default
      # depends on its siblings, which one row can't answer — `primary_id` on the
      # conversations index is the resolved one, so the rule lives in exactly one
      # place (see primary_for).
      primary:          primary?,
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

  # Only when there is nothing to displace: this claims an EMPTY slot and never
  # takes it off another thread. Choosing one is a deliberate act, and a new
  # thread appearing must not quietly redirect somebody's morning briefing.
  #
  # The unique index is the real arbiter, so two threads created at the same
  # instant for a fresh account can't both win — the loser just doesn't get the
  # flag, and `primary_among` still answers correctly from the oldest id.
  # Deliberately not fatal: failing to claim a default is never a reason to
  # refuse someone a conversation.
  def claim_primary_if_first
    return unless buddy?
    return if user.byte_conversations.primary.exists?

    update_columns(primary_at: Time.current)
  rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
    Rails.logger.info("[ByteConversation] primary already claimed for user=#{user_id}: #{e.class}")
  end

  def default_display_name
    case mode.to_sym
    when :bash   then "Terminal"
    when :jarvis then "Jarvis"
    when :buddy  then buddy_name
    else "Byte"
    end
  end
end
