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

  def self.parse_trigger_data(input)
    input = input.permit!.to_h if input.is_a?(::ActionController::Parameters)
    input = input.to_h if input.is_a?(::ActiveSupport::HashWithIndifferentAccess)

    return input.deep_symbolize_keys if input.is_a?(::Hash)
    return { data: input } if input.is_a?(::Array)

    begin
      return parse_trigger_data(::JSON.parse(input)) if input.is_a?(::String)
    rescue ::JSON::ParserError
      # Might be nested string `something:nested:value`
    end

    return { data: input } unless input.is_a?(::String)
    return { data: input } unless input.match?(/\w+(:\w+)+/)

    parse_trigger_data(input.split(":").reverse.reduce { |value, key| { key.to_sym => value } })
  end

  def self.break_searcher(search_string)
    return all if search_string.squish.then { |str| str.blank? || str == "*" }
    trigger, _rest = search_string.split(":", 2)

    schedules = ::ScheduledTrigger.where(trigger: trigger)
    schedules.select do |schedule|
      ::SearchBreakMatcher.new(search_string, { trigger => schedule.data }).match?
    end
  end

  def ready?
    return false if started?
    execute_at < 5.seconds.from_now # offset for minor async issues
  end

  def running? = started? && !completed?

  def delayed_trigger?
    execute_at > created_at + 5.seconds
  end

  def legacy_serialize
    {
      id: id,
      name: name,
      trigger: trigger,
      data: data,
      execute_at: execute_at,
    }
  end
end
