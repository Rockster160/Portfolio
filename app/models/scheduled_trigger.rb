# == Schema Information
#
# Table name: scheduled_triggers
#
#  id                   :bigint           not null, primary key
#  auth_type            :integer
#  completed_at         :datetime
#  condition            :jsonb
#  data                 :jsonb            not null
#  execute_at           :datetime         not null
#  jid                  :text
#  name                 :text
#  offset_seconds       :integer
#  started_at           :datetime
#  trigger              :text             not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  anchor_occurrence_id :bigint
#  auth_type_id         :integer
#  source_item_id       :bigint
#  user_id              :bigint           not null
#
class ScheduledTrigger < ApplicationRecord
  REDIS_OFFSET = 10.minutes
  belongs_to :user
  # Derived from a source AgendaItem with a fixed relative offset. When the
  # source's start_at changes, AgendaItem#propagate_to_derived_triggers
  # rewrites execute_at = source.start_at + offset_seconds. FK cascade
  # destroys these when the source is deleted.
  belongs_to :source_item, class_name: "AgendaItem", optional: true
  # Derived from an Anchor occurrence instead, with the same offset_seconds
  # meaning. Bound to the exact occurrence rather than to the anchor: an anchor
  # may be hourly, daily or weekly, so "the one nearest where this sits" has no
  # window that is right for all of them. FK cascade removes these with it.
  belongs_to :anchor_occurrence, optional: true

  enum :auth_type, ::Execution.auth_types

  timestamp_bool :execute_at, :completed_at, :started_at

  scope :not_scheduled, -> { where(jid: nil) }
  scope :upcoming_soon, -> { not_started.where(execute_at: ..REDIS_OFFSET.from_now) }
  scope :running, -> { started.not_completed }
  scope :ready, -> { not_started.where(execute_at: ..5.seconds.from_now) }
  scope :derived, -> { where.not(source_item_id: nil) }
  scope :anchored, -> { where.not(anchor_occurrence_id: nil) }

  validates :trigger, presence: true
  validates :offset_seconds, presence: true, if: :source_item_id?
  validates :offset_seconds, presence: true, if: :anchor_occurrence_id?
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

  # A truthy check answered when this comes due — see ScheduleCondition. The
  # rescue matches ReminderFirer's: an unanswerable condition FIRES, because a
  # trigger that silently didn't run is indistinguishable from one that never
  # existed, and something downstream is usually waiting on it.
  def condition_met?
    ScheduleCondition.met?(condition, user: user)
  rescue StandardError => e
    Rails.logger.warn("[ScheduledTrigger] condition failed on ##{id}: #{e.class}: #{e.message}")
    true
  end

  # Where a skip gets announced. A trigger has no thread of its own, so it
  # borrows the one the person actually reads — nil when they have none, which
  # `announce_skip!` treats as "log it and move on".
  def buddy_conversation
    return nil if user.nil?

    ByteConversation.for_self_initiated(user)
  end

  def running? = started? && !completed?

  def delayed_trigger?
    execute_at > created_at + 5.seconds
  end
end
