# == Schema Information
#
# Table name: anchors
#
#  id          :bigint           not null, primary key
#  description :text
#  key         :text             not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  user_id     :bigint           not null
#

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

  # Make an expression usable and hand back the moment it resolves to now.
  #
  # This is what makes a class key self-serve: "half an hour before any
  # interview" needs `agenda:interview` to exist, and nobody should have to
  # create it by hand first. A domain the app feeds itself (see
  # AnchorFeeder::FED_DOMAINS) gets its key created and stated on the spot.
  #
  # Any other domain is left to whoever feeds it - `sun:sunset` comes from a Jil
  # task, and creating an empty one here would hand back a key that silently
  # never resolves.
  def self.subscribe!(expression, user:)
    parsed = ::AnchorExpression.parse(expression)
    raise ::ArgumentError, "#{expression} isn't an anchor expression" if parsed.nil?

    key = parsed[:key]
    if self.for(user, key).nil?
      domain = key.split(":").first
      raise ::ArgumentError, "#{key} isn't an anchor you have" unless ::AnchorFeeder::FED_DOMAINS.include?(domain)

      create!(user: user, key: key)
      ::AnchorFeeder.call(user)
    end

    resolve(expression, user: user)
  end

  # The expression as a person would say it: "30 minutes before the next
  # interview", "when leaving comes round".
  #
  # Needed because an anchored schedule has a time only as a CONSEQUENCE. A
  # standing rule with nothing booked has none at all, and a row that shows
  # neither a time nor a rule reads as nothing being set.
  #
  # The three agenda edges are the only keys that need words put to them. Every
  # other one is already a word somebody chose - `agenda:interview`,
  # `agenda:birthdays` - and reads back as itself.
  PHRASES = {
    "agenda:start"  => "anything starting",
    "agenda:end"    => "anything ending",
    "agenda:leave"  => "leaving",
    "trigger:start" => "the next scheduled trigger",
  }.freeze

  def self.describe(expression)
    parsed = ::AnchorExpression.parse(expression)
    return nil if parsed.nil?
    return chore_phrase(parsed) if parsed[:key].start_with?("chore:")

    event   = parsed[:key].split(":").last.tr("_", " ")
    subject = PHRASES[parsed[:key]] || "#{parsed[:identifier] ? "that" : "the next"} #{event}"
    offset  = parsed[:offset_seconds]
    return "when #{subject} comes round" if offset.zero?

    gap = ::ActiveSupport::Duration.build(offset.abs).inspect
    "#{gap} #{offset.negative? ? "before" : "after"} #{subject}"
  end

  # A chore comes due for a DAY rather than at a minute, so its occurrence sits
  # on the chore-day boundary and the offset is really a time of day (see
  # AnchorFeeder). Read back as a gap it would be arithmetic nobody asked for:
  # "7 hours after the next shower" is 11am, said the long way round.
  def self.chore_phrase(parsed)
    name    = parsed[:key].split(":", 2).last.tr("_", " ")
    seconds = ::ChoreDay::CUTOFF_HOURS.hours.to_i + parsed[:offset_seconds]
    return "when #{name} is due" unless (0...(1.day)).cover?(seconds)

    clock = ::Time.current.midnight.since(seconds).strftime("%-l:%M%P").sub(":00", "")
    "#{clock} when #{name} is due"
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
    { triggers: propagate_triggers!, tasks: propagate_tasks!, reminders: propagate_reminders! }
  end

  # A move that puts a trigger in the past removes it rather than letting it
  # fire on the spot - see ScheduledTrigger#follow_source!.
  def propagate_triggers!
    scope = ::ScheduledTrigger.not_started.where(anchor_occurrence_id: occurrences.select(:id))
    scope.includes(:anchor_occurrence).find_each.count { |trigger| trigger.follow_source!.present? }
  end

  # Buddy reminders hang off the EXPRESSION rather than an occurrence, because a
  # standing rule ("half an hour before any interview") is about the next one
  # each time and not about a particular one. So they are re-asked the way a
  # task's cron is: clear `fire_at`, save, and the model resolves it again.
  #
  # A pinned reminder is included and must be: its occurrence moving is exactly
  # the case this exists for, and the identifier means it re-resolves onto the
  # same one.
  def propagate_reminders!
    scope = ::BuddyReminder.pending.where(user_id: user_id).where("anchor ILIKE ?", "%#{key}%")

    scope.find_each.count { |reminder|
      next false unless ::AnchorExpression.parse(reminder.anchor)&.dig(:key) == key

      was      = reminder.fire_at
      resolved = ::Anchor.resolve(reminder.anchor, user: user, after: ::Time.current)

      if resolved.nil?
        # Nothing left to hang off, and what that MEANS depends on which kind of
        # rule it is. A pinned one was about a single occurrence that has now
        # been or been dropped, so it is over rather than due this instant - the
        # same call ScheduledTrigger#follow_source! makes. A standing one is
        # about the next of a class, so it parks and arms again when the next
        # one turns up.
        reminder.anchor_pinned? ? reminder.update!(cancelled_at: ::Time.current) : reminder.update!(fire_at: nil)
      else
        reminder.update!(fire_at: resolved)
      end

      reminder.fire_at != was || reminder.cancelled_at.present?
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
