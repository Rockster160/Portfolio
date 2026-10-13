# Keeps every anchor a person owns stated against what the app actually knows,
# so a reminder or a cron hung off one lands on the right minute and follows it
# when the thing moves. The syntax and the resolution are documented in
# docs/jil_anchors.md; this is only the supply.
#
# Nothing here decides which anchors should exist - the KEY is the
# subscription. `agenda:interview` exists because somebody made a rule about
# interviews, and this fills it; `agenda:dentist` works the same way the moment
# it is created, with no change to this file. That is also why a key in no
# domain below is left alone rather than emptied: `sun:sunset` is fed by a Jil
# task and is none of this file's business.
#
# Under `agenda:`, three event names are an item's own edges - `start`, `end`
# and `leave` - and any other word is matched against item and calendar NAMES,
# which is what makes a class key self-serve. `trigger:start` asks the same
# question of a one-off the person scheduled by hand.
#
# A recurring occurrence counts whether or not it is a row yet. Agenda keeps
# repeats as phantoms until something touches them or they come due, and reading
# the table directly meant a daily task had nothing to hang off until the
# morning it fired - which is the one moment a "half an hour before" rule is
# already too late to be any use.
#
# Completion is deliberately NOT a filter. An anchor answers WHEN, and ticking
# something off does not move it: "ten minutes after my interview" has to
# survive marking the interview done, which is the obvious thing to do the
# moment it ends. "...unless it is already done" is a question about state, and
# a schedule asks that with a condition (see ScheduleCondition) rather than by
# having the time disappear underneath it. Cancelled is different and IS
# dropped - a cancelled thing is not happening at all.
class AnchorFeeder
  # Far enough ahead for "ten days before anybody's birthday" to have something
  # to hang off all year, short enough that a class key is a handful of rows.
  HORIZON = 120.days

  # How many upcoming occurrences to hold per anchor.
  #
  # The horizon has to be long, because a yearly key needs the whole year in
  # view before it can answer anything. A DAILY key inside that same window is
  # 120 occurrences, restated every five minutes, and nothing ever resolves
  # further ahead than the next one plus its offset. So the earliest handful is
  # the same answer for a fraction of the work.
  KEEP_AHEAD = 20

  # The edges, and the method on the item that answers each one. `leave_at` is
  # the travel-derived leave-by, which is only there when a drive is known -
  # an item with no drive contributes nothing rather than its start time.
  AGENDA_EDGES = { "start" => :start_at, "end" => :end_at, "leave" => :leave_at }.freeze

  FED_DOMAINS = %w[agenda trigger].freeze

  def self.call(user) = new(user).call

  def initialize(user)
    @user = user
    @now  = ::Time.current
  end

  # Returns how many occurrences are now standing across the person's anchors.
  def call
    anchors.sum { |anchor| fill(anchor) }
  end

  private

  def anchors
    ::Anchor.where(user_id: @user.id).select { |anchor| FED_DOMAINS.include?(anchor.key.split(":").first) }
  end

  def fill(anchor)
    domain, event = anchor.key.split(":", 2)
    wanted = (
      case domain
      when "agenda"  then agenda_times(event)
      when "trigger" then trigger_times(event)
      end
    )
    return 0 if wanted.nil?

    apply(anchor, wanted)
  end

  # Upsert what belongs and drop what no longer does - a cancelled interview, a
  # renamed item, an occurrence that has fallen off the end of KEEP_AHEAD. Only
  # AHEAD of now: a past
  # occurrence is history the anchor deliberately keeps, and a positive offset
  # may still be pending against it.
  #
  # Occurrences with no identifier are left alone on purpose. SQL's `NOT IN`
  # never matches a NULL, so one appended by hand or by a Jil task survives a
  # pass of this.
  def apply(anchor, wanted)
    wanted.each { |identifier, at| anchor.set_occurrence(at, identifier: identifier) }

    stale = anchor.occurrences.where(occurs_at: @now..).where.not(identifier: wanted.keys)
    stale.find_each { |occurrence| anchor.remove_occurrence(occurrence.identifier) }

    wanted.size
  end

  def agenda_times(event)
    column = AGENDA_EDGES[event]
    items  = agenda_items
    items  = items.select { |item| named?(item, event) } if column.nil?

    found = items.filter_map { |item|
      at = item.public_send(column || :start_at)
      [occurrence_key(item), at] if in_window?(at)
    }

    found.sort_by(&:last).first(KEEP_AHEAD).to_h
  end

  # Everything on the person's calendar across the horizon, phantoms included -
  # the same builder the calendar itself draws from, so an anchor sees exactly
  # what they see, overrides and excluded dates and all.
  #
  # Read ONCE per pass rather than per anchor: building phantoms walks every
  # date in the horizon against every repeat, and somebody with five agenda
  # anchors was paying for that five times over.
  def agenda_items
    @agenda_items ||= @user.agenda_items_for_range(@now.to_date, (@now + HORIZON).to_date)
  end

  # What an occurrence is CALLED, and it has to survive materialization: a
  # phantom becomes a real row with a database id of its own the moment it comes
  # due or gets touched. Keyed on that id, the pass after would drop the
  # occurrence a reminder is bound to and add an identical one under a new name.
  # A recurring occurrence is its rule and its date either way.
  #
  # A detached row is standalone on the date it now sits on, so it keeps its own
  # id - its rule's occurrence is a separate thing that may still be there.
  def occurrence_key(item)
    return item.id.to_s if item.agenda_schedule_id.blank? || item.detached?

    "#{item.agenda_schedule_id}:#{item.occurrence_date.iso8601}"
  end

  # The calendar's name counts as well as the item's, so a key named after a
  # whole calendar ("agenda:birthdays") picks up everything on it even where
  # the rows are named after people.
  def named?(item, event)
    term = event.to_s.tr("_", " ")
    return false if term.blank?

    "#{item.name} #{item.agenda&.name}".downcase.include?(term.downcase)
  end

  def trigger_times(event)
    return nil unless event == "start"

    scope = ::ScheduledTrigger.where(user_id: @user.id).not_started.where(execute_at: @now..(@now + HORIZON))
    scope.each_with_object({}) { |trigger, found| found[trigger.id.to_s] = trigger.execute_at }
  end

  def in_window?(at) = at.present? && at > @now && at < @now + HORIZON
end
