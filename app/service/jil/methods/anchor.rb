# Jil bindings for Anchors - named times that schedules can hang off.
#
# This is the whole point of the anchor system: a new anchor is DATA, not code.
# A task writes a time under a key, and that key is immediately usable in any
# task's cron as `key-5m`. Nothing in Ruby needs to learn what the key means.
#
#   Anchor.set("sun:sunset", sunset_time, "2026-08-19")
#
# Passing the same identifier again REPLACES that occurrence rather than adding
# another, which is what lets an hourly refresh restate the same days without
# piling up duplicates. Every write re-resolves whatever is scheduled against
# the anchor - see Anchor#propagate!.
class Jil::Methods::Anchor < Jil::Methods::Base
  GETTER_ATTRS = [:id, :key, :description].freeze

  def cast(value)
    case value
    when ::Anchor then value
    when ::Numeric then @jil.user.anchors.find_by(id: value)
    when ::Hash then ::Anchor.for(@jil.user, value[:key])
    when ::ActiveRecord::Relation then cast(value.one? ? value.first : value.to_a)
    else ::Anchor.for(@jil.user, value)
    end
  end

  def execute(line)
    method_sym = line.methodname.to_s.underscore.gsub(/[^\w]/, "").to_sym
    if token_class(line.objname) == :Anchor && GETTER_ATTRS.include?(method_sym)
      return token_val(line.objname)[method_sym]
    end

    fallback(line)
  end

  # Upsert an occurrence, creating the anchor itself the first time. `id` is
  # optional - without it the time is simply appended.
  def set(key, at, id=nil)
    anchor = upsert_anchor(key)
    return nil if anchor.nil?

    time = @jil.cast(at, :Date)
    return nil if time.blank?

    anchor.set_occurrence(time, identifier: id)
    anchor
  end

  # Drop one occurrence by identifier. The anchor itself stays, so a cron
  # pointing at it keeps validating.
  def remove(key, id)
    ::Anchor.for(@jil.user, key)&.remove_occurrence(id).present?
  end

  # Drop every occurrence, keeping the anchor. What a feeder calls when it wants
  # to restate a schedule from scratch rather than upsert into it.
  def clear(key)
    anchor = ::Anchor.for(@jil.user, key)
    return false if anchor.nil?

    anchor.occurrences.destroy_all
    true
  end

  # Forget the anchor entirely. Any cron still naming it stops validating, which
  # is the intended loud failure rather than a schedule that quietly never runs.
  def destroy(key)
    ::Anchor.for(@jil.user, key)&.destroy.present?
  end

  # The next time this anchor comes due. Accepts the offset syntax too, so
  # `Anchor.next("sun:sunset-5m")` answers what a cron of the same string would.
  def next(expression)
    ::Anchor.resolve(expression, user: @jil.user) ||
      ::Anchor.for(@jil.user, expression)&.next_at(after: ::Time.current)
  end

  def list
    @jil.user.anchors.order(:key).to_a
  end

  # Schedule a trigger against an anchor. `expression` carries the offset the
  # same way a cron does, so `Anchor.trigger("sun:sunset-5m", ...)` fires the
  # `scope` listener five minutes before the next sunset.
  #
  # Bound to the occurrence it resolved to, so if that time later moves the
  # trigger moves with it. Keyed by (occurrence, name), so calling this again
  # for the same occurrence updates that row rather than stacking another.
  #
  # Use this for a ONE occurrence at a time job - a pre-event reminder, a
  # leave-by alert. For "every sunset, forever", give a task the cron instead;
  # it re-arms itself and needs no feeder to keep scheduling it.
  def trigger(expression, name, scope, data=nil)
    return nil if name.blank? || scope.blank?

    found = ::Anchor.occurrence_for(expression, user: @jil.user)
    return nil if found.nil?

    occurrence, offset = found
    execute_at = occurrence.occurs_at + offset

    # Already gone by - refuse rather than create something that fires the
    # instant it exists, which reads as "the reminder arrived at the event".
    if execute_at <= ::Time.current
      untrigger(expression, name)
      return nil
    end

    record = @jil.user.scheduled_triggers.where(
      anchor_occurrence_id: occurrence.id, name: name.to_s,
    ).first_or_initialize
    was_new = record.new_record?

    record.update!(
      trigger:        scope.to_s,
      execute_at:     execute_at,
      offset_seconds: offset,
      data:           @jil.cast(data.presence || {}, :Hash),
      auth_type:      :trigger,
      auth_type_id:   @jil.task&.id,
    )

    ::Jil::Schedule.update(record)
    ::Jil::Schedule.broadcast(record, was_new ? :created : :updated)
    record
  end

  # Tear-down counterpart. Takes the same expression so a rule whose condition
  # stopped holding can undo itself with the string it scheduled with.
  def untrigger(expression, name)
    found = ::Anchor.occurrence_for(expression, user: @jil.user)
    return false if found.nil?

    record = @jil.user.scheduled_triggers.find_by(
      anchor_occurrence_id: found.first.id, name: name.to_s,
    )
    return false if record.nil?

    ::Jil::Schedule.cancel(record)
    record.destroy.destroyed?
  end

  # Housekeeping a feeder can call after restating its schedule.
  def prune(key)
    ::Anchor.for(@jil.user, key)&.prune!.to_i
  end

  def upsert_anchor(key)
    key = key.to_s.downcase.strip
    return nil if key.blank?

    anchor = @jil.user.anchors.find_or_initialize_by(key: key)
    return anchor if anchor.persisted? || anchor.save

    nil
  end
end
