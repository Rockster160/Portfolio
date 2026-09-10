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
  validates :body, presence: true

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
    }
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
