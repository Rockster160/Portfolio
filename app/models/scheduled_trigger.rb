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
#  source_edge          :integer          default("start"), not null
#  started_at          :datetime
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
  # Which edge of the source AgendaItem offset_seconds is measured from -
  # trigger_for uses start_at, trigger_for_end uses end_at. Propagation has to
  # know, or a "10 min before it ends" lands 10 min before it STARTS on a move.
  enum :source_edge, { start: 0, end: 1 }, prefix: true

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

  # Where a derived row belongs given its source as it stands now. nil when the
  # edge it hangs off is gone - an end-anchored row whose item lost its end_at.
  def derived_execute_at
    edge = (
      if anchor_occurrence_id?
        anchor_occurrence&.occurs_at
      elsif source_edge_end?
        source_item&.end_at
      else
        source_item&.start_at
      end
    )
    edge && (edge + offset_seconds.to_i)
  end

  # Moves a pending derived row onto `derived_execute_at`, or removes it when
  # that has already gone by. The create paths (trigger_for, Anchor.trigger)
  # refuse a past time because it fires the instant it exists; a MOVE into the
  # past is the same trigger arriving by another road, so it gets the same
  # answer. Returns :moved, :removed, or nil when it was already right.
  #
  # Unmoved is checked BEFORE past: a source write visits every pending row on
  # it, and one that is simply due - waiting on the runner, or a positive offset
  # off an earlier occurrence - is not this move's to delete.
  def follow_source!
    at = derived_execute_at
    return remove_derived! if at.nil?
    return nil if at == execute_at
    return remove_derived! if at <= ::Time.current

    update_columns(execute_at: at)
    ::Jil::Schedule.update(self)
    :moved
  end

  def remove_derived!
    ::Jil::Schedule.cancel(self)
    destroy!
    :removed
  end

  def running? = started? && !completed?

  def delayed_trigger?
    execute_at > created_at + 5.seconds
  end
end
