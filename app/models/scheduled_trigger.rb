# == Schema Information
#
# Table name: scheduled_triggers
#
#  id           :bigint           not null, primary key
#  completed_at :datetime
#  data         :jsonb            not null
#  execute_at   :datetime         not null
#  jid          :text
#  name         :text
#  started_at   :datetime
#  trigger      :text             not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  user_id      :bigint           not null
#
class ScheduledTrigger < ApplicationRecord
  REDIS_OFFSET = 10.minutes
  belongs_to :user

  timestamp_bool :execute_at, :completed_at, :started_at

  scope :not_scheduled, -> { where(jid: nil) }
  scope :upcoming_soon, -> { not_started.where(execute_at: ..REDIS_OFFSET.from_now) }
  scope :running, -> { started.not_completed }
  scope :ready, -> { not_started.where(execute_at: ..5.seconds.from_now) }

  validates :trigger, presence: true

  def self.break_searcher(search_string)
    return all if search_string.squish.then { |str| str.blank? || str == "*" }

    trigger, _rest = search_string.split(":", 2)

    schedules = where(trigger: trigger)
    schedules.select { |schedule|
      ::SearchBreakMatcher.new(search_string, { trigger => schedule.data }).match?
    }
  end

  def ready?
    return false if started?

    execute_at < 5.seconds.from_now # offset for minor async issues
  end

  def running? = started? && !completed?

  def delayed_trigger?
    execute_at > created_at + 5.seconds
  end
end
