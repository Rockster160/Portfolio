# == Schema Information
#
# Table name: buddy_alerts
#
#  id                   :bigint           not null, primary key
#  body                 :text             not null
#  key                  :text             not null
#  last_raised_at       :datetime         not null
#  metadata             :jsonb            not null
#  raised_at            :datetime         not null
#  raised_count         :integer          default(1), not null
#  resolution           :text
#  resolved_at          :datetime
#  status               :integer          default("open"), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint           not null
#  byte_message_id      :bigint
#  user_id              :bigint           not null
#
class BuddyAlert < ApplicationRecord
  # Something that needs doing, standing open until it's dealt with.
  #
  # The difference between this and every other thing Buddy says is that it has
  # a LIFECYCLE. A doorbell ring is news and then it's over; "the laundry gate
  # is open" is a condition, and it stays true until somebody closes the gate.
  # So it owns its bubble: the same message row is rewritten when the condition
  # clears, rather than a second one arriving to contradict the first.
  #
  # `key` is the identity of the condition, chosen by whoever raises it. It is
  # what makes a second raise the SAME issue rather than another one, and what
  # a resolve names when it comes in from somewhere else entirely — the sensor
  # that clears it is rarely the sensor that noticed it.
  #
  # Repeats are counted, never swallowed: the gate being found open three times
  # is three real events, and `raised_count` / `last_raised_at` are what keep
  # them on the record and on the bubble. One bubble is not one event — it is
  # one CONDITION, and the times it recurred are part of what it says.
  belongs_to :user
  belongs_to :byte_conversation
  belongs_to :byte_message, optional: true

  # `dismissed` is the escape hatch, and the reason it exists is that an alert
  # nobody deals with is worse than one nobody sees: while it stands open the
  # key is taken, so every later occurrence lands on the same buried bubble
  # rather than announcing itself. Letting go of one frees the key, and the next
  # occurrence opens fresh and buzzes like the first did.
  #
  # It is NOT `resolved`, and the bubble says so. Nobody claimed the condition
  # cleared — they said stop asking, which is a different fact.
  enum :status, { open: 0, resolved: 1, dismissed: 2 }, prefix: :status

  # How long a standing condition may go without buzzing again. A repeat while
  # the bubble is fresh is something they were told about minutes ago; a repeat
  # a day later is a problem that has outlived their memory of it, and going on
  # silently is how an ignored alert quietly eats every occurrence after it.
  PUSH_AGAIN_AFTER = 12.hours

  validates :key, presence: true
  # A board-only hold may be a look with no words (Buddy::Alerts.hold! with a
  # mood or a face); everything else has something to say.
  validates :body, presence: true, unless: :look_only?

  scope :for_key,     ->(key) { where(key: key.to_s.strip) }
  scope :newest,      -> { order(last_raised_at: :desc) }
  scope :outstanding, -> { status_open.order(raised_at: :asc) }

  # The one that a resolve should land on. There can only be one — the partial
  # unique index says so — but this is the reading side of that rule.
  def self.open_for(user, key)
    status_open.where(user_id: user.id).for_key(key).first
  end

  # What the bubble carries, so the client can draw the state without inferring
  # it from the words. `count` is only interesting above one: a condition that
  # happened once says so by saying nothing.
  #
  # `resolved_at` is stamped whenever the alert stops standing open, whichever
  # way that happened — `status` is what says which.
  def wire
    {
      "key"            => key,
      "status"         => status,
      "raised_at"      => raised_at&.iso8601,
      "last_raised_at" => last_raised_at&.iso8601,
      "resolved_at"    => resolved_at&.iso8601,
      "count"          => raised_count,
    }
  end

  # One row of the outstanding strip. It carries the conversation and message so
  # a tap can go to the bubble the words came from, which may be in another
  # thread and days back.
  def strip_wire
    {
      "id"              => id,
      "key"             => key,
      "body"            => body,
      "count"           => raised_count,
      "raised_at"       => raised_at&.iso8601,
      "conversation_id" => byte_conversation_id,
      "message_id"      => byte_message_id,
      "groups"          => groups,
      "icon"            => icon,
      "expression"      => expression,
      "faces"           => faces,
      "strength"        => strength,
      "board_only"      => board_only?,
      "dream"           => dream?,
      "last_raised_at"  => last_raised_at&.iso8601,
    }
  end

  # Shown on its boards only - no bubble in the thread, no push, no row in the
  # chat strip. See Buddy::Alerts.hold!.
  def board_only?
    metadata["board_only"] == true
  end

  # A want or an idea rather than a condition: shown in the board pet's thought
  # bubble, not its speech bubble. Always board-only.
  def dream?
    metadata["dream"] == true
  end

  # The groups this alert is aimed at, which a board matches against the ones it
  # watches to decide whether to show it. Empty means it belongs to no board —
  # it stands in the chat strip only.
  def groups
    Array(metadata["groups"]).map(&:to_s)
  end

  # An optional glyph the board shows in place of the sentence — a hungry dog's
  # 🍖, say, read from across the room where a line of text can't be. The chat
  # strip ignores it and keeps the words; it is the wall that wants the icon.
  def icon
    metadata["icon"].to_s.strip.presence
  end

  # The face the board's pet HOLDS while this condition stands — the laundry
  # gate's "up to no good" look, say — by name. Only a pet with that drawing
  # wears it (see #face_for). Blank, with no mood either, means the generic
  # alarm shuffle.
  def expression
    metadata["expression"].to_s.strip.presence
  end

  # The look it was raised with as a point on the faces' axes (Buddy::Moods),
  # or nil when it names a face instead, or none.
  def mood
    metadata["mood"].presence
  end

  # Only a look: nothing to say, so no bubble anywhere.
  def look_only?
    board_only? && body.blank? && (mood.present? || expression.present?)
  end

  # The face a pet of this theme wears for it: the face it names, when this pet
  # has it; else its mood as this pet answers it (seeded by when it was raised,
  # so the pet keeps one face while it stands); else nil, and the pet keeps to
  # its own feelings.
  def face_for(theme)
    named = ::Buddy::Faces.named(theme, expression) if expression
    return named.to_s if named
    return nil if mood.nil?

    ::Buddy::Moods.face(theme, mood, seed: mood_seed)&.to_s
  end

  # { theme => face } for every pet with an answer, so any board can paint it
  # as is. Nil when it asks for no look at all.
  def faces
    return nil if mood.nil? && expression.nil?

    ::Buddy::Companion.all.keys.each_with_object({}) { |theme, faces|
      face = face_for(theme)
      faces[theme.to_s] = face if face
    }
  end

  def mood_seed
    "#{key}:#{raised_at&.to_i}"
  end

  # How strongly its face wants the pet (see Buddy::FaceStrength): what it was
  # raised with, else a dream's or an alert's usual.
  def strength
    fallback = dream? ? ::Buddy::FaceStrength::DREAM : ::Buddy::FaceStrength::ALERT
    ::Buddy::FaceStrength.named(metadata["strength"], fallback)
  end

  # When it last buzzed. Held in metadata rather than a column of its own: it is
  # read once per raise and never queried on.
  def notified_at
    ::Time.zone.parse(metadata["notified_at"].to_s) if metadata["notified_at"].present?
  rescue ArgumentError
    nil
  end

  def push_again?
    at = notified_at
    at.nil? || at < PUSH_AGAIN_AFTER.ago
  end
end
