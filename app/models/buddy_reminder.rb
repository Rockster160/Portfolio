# == Schema Information
#
# Table name: buddy_reminders
#
#  id                   :bigint           not null, primary key
#  body                 :text             not null
#  cancelled_at         :datetime
#  fire_at              :datetime         not null
#  fired_at             :datetime
#  kind                 :string           default("reminder"), not null
#  last_fired_at        :datetime
#  metadata             :jsonb            not null
#  recurrence           :jsonb
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  byte_conversation_id :bigint           not null
#  user_id              :bigint           not null
#
class BuddyReminder < ApplicationRecord
  belongs_to :user
  belongs_to :byte_conversation

  KINDS = %w[reminder prompt].freeze

  # `pending` = neither fired-terminally nor cancelled. Recurring
  # reminders never set `fired_at` - they set `last_fired_at` and roll
  # `fire_at` forward to the next occurrence, so they stay in `pending`
  # forever until cancelled.
  scope :pending, -> { where(fired_at: nil, cancelled_at: nil) }
  scope :due,     ->(now = Time.current) { pending.where("fire_at <= ?", now) }
  scope :upcoming, ->(now = Time.current, limit_hours = 48) {
    pending.where("fire_at > ?", now).where("fire_at < ?", now + limit_hours.hours).order(:fire_at)
  }

  validates :body,    presence: true, length: { maximum: 500 }
  validates :fire_at, presence: true
  validates :kind,    inclusion: { in: KINDS }

  def recurring?
    recurrence.is_a?(Hash) && recurrence["kind"].present?
  end

  # A pending reminder that already means THIS, at this minute, or nil.
  #
  # Asking again about something you already asked about is the normal shape of
  # a conversation, and Buddy has no memory of having set one three hours ago -
  # `upcoming_reminders` is available and simply wasn't read. Prod: "please
  # alert me of both of those items" produced second copies of two reminders
  # set that morning, and both fired twice, at 3:15 and again at 3:35.
  #
  # Same MINUTE and a shared word, both required. Same minute alone would
  # collapse "check the oven" and "call mom" at six o'clock into one, and
  # losing a real reminder is a worse failure than the double ping this exists
  # to stop. Recurring ones are left out of the comparison entirely: a daily
  # 9am and a one-off tomorrow at 9am are genuinely different requests.
  def self.clashing(user, text, fire_at)
    words = significant_words(text)
    return nil if words.empty? || fire_at.blank?

    minute = fire_at.change(sec: 0)
    pending.where(user_id: user.id, recurrence: nil)
      .where(fire_at: minute...(minute + 1.minute))
      .find { |r| significant_words(r.body).intersect?(words) }
  end

  # Words worth matching on: everything that isn't scaffolding. Deliberately a
  # small list rather than a real stemmer - the comparison only has to separate
  # "outfit" from "meatloaf", and it's already narrowed to one minute.
  FILLER = <<~WORDS.split.to_set.freeze
    about after alert and are before check do done for get got going make made
    my need needs please put remind reminder take that the then this you your
  WORDS

  def self.significant_words(text)
    text.to_s.downcase.scan(/[a-z]+/).reject { |w| w.length < 3 || FILLER.include?(w) }.to_set
  end

  # Compute the next fire_at from the recurrence spec + a base moment.
  # Supported shapes:
  #   { "kind" => "daily",   "at" => "21:00" }
  #   { "kind" => "weekly",  "weekday" => "wednesday", "at" => "20:00" }
  #   { "kind" => "weekdays","at" => "09:00" }             # Mon-Fri
  #   { "kind" => "monthly", "day" => 1, "at" => "09:00" }
  # Returns nil for unknown shapes so the firer can mark them terminal.
  def next_fire_at(from: Time.current)
    return nil unless recurring?

    tz = ActiveSupport::TimeZone[user.timezone] || Time.zone
    from_local = from.in_time_zone(tz)
    hh, mm = (recurrence["at"] || "09:00").split(":").map(&:to_i)

    case recurrence["kind"]
    when "daily"
      candidate = from_local.change(hour: hh, min: mm)
      candidate <= from_local ? candidate + 1.day : candidate
    when "weekdays"
      candidate = from_local.change(hour: hh, min: mm)
      candidate += 1.day while candidate <= from_local || candidate.saturday? || candidate.sunday?
      candidate
    when "weekly"
      target = weekday_index(recurrence["weekday"])
      return nil if target.nil?
      candidate = from_local.change(hour: hh, min: mm)
      candidate += 1.day until candidate.wday == target && candidate > from_local
      candidate
    when "monthly"
      day = (recurrence["day"] || 1).to_i.clamp(1, 28)
      candidate = from_local.change(day: day, hour: hh, min: mm)
      candidate <= from_local ? candidate + 1.month : candidate
    end
  end

  private

  def weekday_index(name)
    %w[sunday monday tuesday wednesday thursday friday saturday].index(name.to_s.downcase)
  end
end
