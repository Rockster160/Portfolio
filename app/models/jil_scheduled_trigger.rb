# == Schema Information
#
# Table name: jil_scheduled_triggers
#
#  id         :bigint           not null, primary key
#  data       :jsonb            not null
#  execute_at :datetime         not null
#  jid        :text
#  trigger    :text             not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  user_id    :bigint           not null
#
class JilScheduledTrigger < ApplicationRecord
  REDIS_OFFSET = 10.minutes
  belongs_to :user

  scope :not_scheduled, -> { where(jid: nil) }
  scope :upcoming_soon, -> { where(execute_at: ..REDIS_OFFSET.from_now) }

  def self.break_searcher(search_string)
    return all if search_string.squish.then { |str| str.blank? || str == "*" }
    trigger, _rest = search_string.split(":", 2)

    schedules = ::JilScheduledTrigger.where(trigger: trigger)
    schedules.select do |schedule|
      ::SearchBreakMatcher.new(search_string, { trigger => schedule.data}).match?
    end
  end

  def ready?
    execute_at < 5.seconds.from_now # offset for minor async issues
  end

  def serialize
    {
      id: id,
      trigger: trigger,
      data: data,
      execute_at: execute_at,
    }
  end
end
