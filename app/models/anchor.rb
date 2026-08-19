# A named point in time that something else can be scheduled against.
#
# An anchor holds no logic and computes nothing. It is a key the user owns
# ("sun:sunset", "trash:pickup", "school:bell") plus the upcoming timestamps
# somebody told it about - normally a Jil task, via Jil::Methods::Anchor. That
# is the whole point: adding a new anchor is something you do from a task, not
# something anyone edits Ruby for.
#
# The value being allowed to MOVE is what makes this worth a record rather than
# a cron string. A cron resolves once and is then a fixed stamp; an anchor keeps
# the question, so everything scheduled against it can be re-asked and corrected
# when the answer changes - see `propagate!`.
#
# The expression syntax, the retention rule and the Jil calls are documented in
# docs/jil_anchors.md.
class Anchor < ApplicationRecord
  belongs_to :user
  has_many :occurrences, class_name: "AnchorOccurrence", dependent: :destroy, inverse_of: :anchor

  validates :key, presence: true, uniqueness: { scope: :user_id }
  validates :key, format: {
    with:    AnchorExpression::KEY_SHAPED,
    message: "must look like domain:event, e.g. sun:sunset",
  }

  # How many already-past occurrences to keep per anchor. Counted rather than
  # aged on purpose: an anchor may be hourly, daily or weekly, and any fixed
  # duration would be far too long for one and too short for another. Keeping
  # the last N means the retained history always spans N of that anchor's own
  # intervals, whatever they happen to be.
  #
  # Past ones are worth keeping at all because a positive offset fires AFTER the
  # moment - `sun:sunset+1h` is still pending an hour later, and the occurrence
  # it is bound to has to still be there.
  KEEP_PAST = 10

  before_validation { self.key = key.to_s.downcase.strip.presence }

  def self.for(user, key)
    find_by(user_id: ::User.id(user), key: key.to_s.downcase.strip)
  end

  def self.keys_for(user)
    where(user_id: ::User.id(user)).order(:key).pluck(:key)
  end

  # The next time `expression` comes due, strictly after `after`. nil when the
  # anchor is unknown OR has nothing left ahead of that point - the caller
  # decides which of those matters to it.
  def self.resolve(expression, user: nil, after: nil)
    found = occurrence_for(expression, user: user, after: after)
    return nil if found.nil?

    occurrence, offset = found
    occurrence.occurs_at + offset
  end

  # The occurrence an expression lands on, and the offset to apply - so a caller
  # that needs to REMEMBER which one it bound to (a derived trigger) gets the
  # identity rather than just the time.
  def self.occurrence_for(expression, user: nil, after: nil)
    parsed = ::AnchorExpression.parse(expression)
    return nil if parsed.nil? || user.nil?

    anchor = self.for(user, parsed[:key])
    return nil if anchor.nil?

    occurrence = anchor.next_occurrence(
      after:          after || ::Time.current,
      offset_seconds: parsed[:offset_seconds],
      identifier:     parsed[:identifier],
    )
    occurrence && [occurrence, parsed[:offset_seconds]]
  end

  # Strictly greater than, never equal: a task re-resolves the instant it fires,
  # and `>=` would hand back the occurrence it just ran, leaving next_trigger_at
  # equal to now. JilRunnerWorker would find it pending again immediately and
  # loop. The offset moves the comparison rather than the result, because what
  # has to still be ahead is the OFFSET time, not the moment itself.
  def next_occurrence(after:, offset_seconds: 0, identifier: nil)
    scope = occurrences.where("occurs_at > ?", after - offset_seconds)
    scope = scope.where(identifier: identifier) if identifier.present?

    scope.order(:occurs_at).first
  end

  def next_at(after:, offset_seconds: 0, identifier: nil)
    next_occurrence(after: after, offset_seconds: offset_seconds, identifier: identifier)
      &.then { |occurrence| occurrence.occurs_at + offset_seconds }
  end

  # Upsert one occurrence. With an identifier this rewrites that same occurrence
  # every time, so an hourly refresh restating the same eight days converges
  # instead of piling up duplicates. Without one it simply appends.
  def set_occurrence(occurs_at, identifier: nil)
    identifier = identifier.presence&.to_s
    record = (
      if identifier
        occurrences.find_or_initialize_by(identifier: identifier)
      else
        occurrences.build
      end
    )

    record.update!(occurs_at: occurs_at)
    prune!
    record
  end

  def remove_occurrence(identifier)
    occurrences.find_by(identifier: identifier.to_s)&.destroy
  end

  # Everything scheduled against this anchor, moved onto the current answer.
  #
  # Tasks re-resolve wholesale: `Task#set_next_cron` recomputes from the cron, so
  # saving is the whole fix. Derived triggers are bound to a specific occurrence
  # by FK, so they follow that one exactly - no window, no nearest-match, and
  # nothing that assumes the anchor repeats daily.
  def propagate!
    { triggers: propagate_triggers!, tasks: propagate_tasks! }
  end

  def propagate_triggers!
    ::ScheduledTrigger.not_started.where(anchor_occurrence_id: occurrences.select(:id))
      .includes(:anchor_occurrence).find_each.count { |trigger|
        at = trigger.anchor_occurrence.occurs_at + trigger.offset_seconds.to_i
        next false if at == trigger.execute_at

        trigger.update_columns(execute_at: at)
        ::Jil::Schedule.update(trigger)
        true
      }
  end

  def propagate_tasks!
    domain = key.split(":").first

    user.tasks.active.enabled.where("cron ILIKE ?", "%#{domain}:%").find_each.count { |task|
      next false unless ::CronParse.anchors(task.cron).include?(key)

      was = task.next_trigger_at
      task.save!
      task.next_trigger_at != was
    }
  end

  # Trim history to KEEP_PAST, never dropping one a pending trigger is still
  # bound to - that trigger has not fired yet and would lose its anchor.
  def prune!
    past = occurrences.where(occurs_at: ..::Time.current).order(occurs_at: :desc)
    stale = past.offset(KEEP_PAST).pluck(:id)
    return 0 if stale.empty?

    pending = ::ScheduledTrigger.not_started.where(anchor_occurrence_id: stale).pluck(:anchor_occurrence_id)
    droppable = stale - pending
    return 0 if droppable.empty?

    occurrences.where(id: droppable).delete_all
  end
end
