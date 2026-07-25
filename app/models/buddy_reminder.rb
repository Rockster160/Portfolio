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
# A scheduled thing Buddy will surface to the user at fire_at.
#
# kind:
#   "reminder"  - plain text nudge. Body is delivered as an inbound
#                 buddy message + push notification.
#   "prompt"    - a fresh turn is triggered with `body` as the user's
#                 synthetic input (like the quick-action buttons do)
#                 so Buddy composes a contextual reply at fire_at.
#
# Cancellation: set cancelled_at. The sweep worker skips anything
# with cancelled_at OR fired_at present.
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
