# == Schema Information
#
# Table name: scheduled_triggers
#
#  id             :bigint           not null, primary key
#  auth_type      :integer
#  completed_at   :datetime
#  data           :jsonb            not null
#  execute_at     :datetime         not null
#  jid            :text
#  name           :text
#  offset_seconds :integer
#  started_at     :datetime
#  trigger        :text             not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  auth_type_id   :integer
#  source_item_id :bigint
#  user_id        :bigint           not null
#
class ScheduledTrigger < ApplicationRecord
  REDIS_OFFSET = 10.minutes
  belongs_to :user
  # Derived from a source AgendaItem with a fixed relative offset. When the
  # source's start_at changes, AgendaItem#propagate_to_derived_triggers
  # rewrites execute_at = source.start_at + offset_seconds. FK cascade
  # destroys these when the source is deleted.
  belongs_to :source_item, class_name: "AgendaItem", optional: true

  enum :auth_type, ::Execution.auth_types

  timestamp_bool :execute_at, :completed_at, :started_at

  scope :not_scheduled, -> { where(jid: nil) }
  scope :upcoming_soon, -> { not_started.where(execute_at: ..REDIS_OFFSET.from_now) }
  scope :running, -> { started.not_completed }
  scope :ready, -> { not_started.where(execute_at: ..5.seconds.from_now) }
  scope :derived, -> { where.not(source_item_id: nil) }

  validates :trigger, presence: true
  validates :offset_seconds, presence: true, if: :source_item_id?
  validates :name, presence: true, if: :source_item_id?
  validates :name, uniqueness: { scope: [:user_id, :source_item_id] }, if: :source_item_id?

  def self.break_searcher(search_string)
    return all if search_string.squish.then { |str| str.blank? || str == "*" }

    trigger, _rest = search_string.split(":", 2)

    schedules = where(trigger: trigger)
    schedules.select { |schedule|
      ::Tokenizing::Matcher.new(search_string, { trigger => schedule.data }).match?
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
