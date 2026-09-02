Buddy::Tools.register(
  name:        :edit_agenda_item,
  description: <<~TXT,
    Edit an existing agenda item - change its title, time, duration, place, or
    which CALENDAR it sits on, or cancel it. Only include the fields that are
    changing. Use `cancelled=true` to cancel an event without deleting it.

    **Moving an item to another calendar is an edit, not an add.** "Move
    Costco Run to Ours", "put that on the shared calendar", "that belongs on
    Tasks" - all of them are this tool with `calendar` set. Reaching for
    add_agenda_item instead leaves the original sitting where it was and gives
    them the same thing twice.

    **Turning a to-do into something that occupies time is also an edit.**
    "Make that a 3 hour event", "that should be an event, not a task", "just
    make it a task" - `kind`, on the row that's already there. Deleting it and
    adding it back is not the answer, and neither is telling them it can't be
    done.

    **A repeating item is a SERIES, and moving one to another calendar means the
    whole series unless they say otherwise.** Changing only the occurrence in
    front of you leaves the rule pointing at the old calendar, so next week it
    is back where it started - pass `series=true`. An occurrence that has no row
    of its own yet (anything further out than about a day) can ONLY be changed
    through the series, and this does that automatically.

    **"LEAVE at 4" IS NOT "start at 4" - use `leave_at`, never `at`.** For
    anywhere with a drive, the time they say out loud is usually the one they
    walk out of the door, and `at` is always the START. Pass `leave_at` and the
    start is worked back from the item's own drive time and how early they like
    to arrive - which is a number this app HAS and you do not. Do not compute it
    yourself and do not quote a drive time from memory: asked to move an event
    so they could leave at 4, the reply said "about 20 minutes of drive" for a
    32-minute one and set the start to 4:00, and the correction after it set the
    start to the OLD leave time (prod 5144-5147).

    "We want to leave at 4", "set it so I'm out the door by 8:30", "I need to
    leave by quarter past" - all `leave_at`. "Move it to 4", "start at 4",
    "put it at 4 o'clock" - all `at`. Never both in one call.

    If there is no drive time on the item yet, this comes back and says so -
    then ask whether they meant the start, rather than guessing.

    For v1, only edits local (non-Google-synced) items.
  TXT
  feature:     :agenda,
  args:        {
    item:      { type: :string,       required: true,  description: "Fuzzy title of the item to edit" },
    hint_date: { type: :string,       required: false, description: "Date hint (YYYY-MM-DD) for disambiguation" },
    title:     { type: :string,       required: false, description: "New title" },
    at:        { type: :iso_time,     required: false, description: "New local wall-clock START, 24-hour. Moving something on today's calendar puts it AHEAD of the current time. If they said LEAVE, use `leave_at` instead" },
    leave_at:  { type: :iso_time,     required: false, description: "The time they want to LEAVE, 24-hour local. The start is worked back from the item's own drive time and arrive-early minutes. Never pass this together with `at`" },
    duration:  { type: :duration_min, required: false, description: "New duration in minutes" },
    location:  { type: :string,       required: false, description: "New place/venue" },
    calendar:  { type: :string,       required: false, description: "Move it to this calendar, by name (e.g. 'Ours')" },
    kind:      {
      type:        :enum,
      required:    false,
      values:      %i[task event],
      description: "Change WHAT IT IS. `event` occupies a span (pass `duration` too, or it takes 30 minutes); " \
                   "`task` is a to-do at a single time and drops the span entirely",
    },
    cancelled: { type: :string,       required: false, description: "'true' to cancel" },
    series:    { type: :string,       required: false, description: "'true' to change the whole repeating series rather than this one occurrence. Moving a repeating item to another calendar is almost always the series" },
  },
  confirm:     ->(payload, ctx) {
    item = ctx.resolve_agenda_item(payload[:item], hint_date: payload[:hint_date])
    raise "no agenda item matching #{payload[:item].inspect}" if item.nil?
    raise "cannot edit Google-synced items yet" if item.agenda.managed_externally?

    # A trigger row fires an automation off the calendar. Converting one to a
    # task would leave the automation attached to something that no longer runs
    # it, so it's refused rather than silently reshaped.
    if payload[:kind].present? && item.trigger?
      raise "#{item.name} is an agenda trigger, not a task or an event - it can't be converted"
    end

    # A phantom carries no id: the occurrence they named exists only as a rule,
    # so the rule is the only thing there is to edit. Otherwise it is theirs to
    # choose, and `series` is how they say so.
    series = item.id.nil? || payload[:series].to_s == "true"
    raise "#{item.name} isn't a repeating item" if series && item.agenda_schedule_id.blank?

    # `was_kind` is what the row IS, carried so the checklist can say "Edit
    # Task" rather than "Edit Event" on a to-do. `kind` is what it's BECOMING,
    # which is the same thing unless they asked to convert it.
    resolved = { agenda_item_id: item.id, was_kind: item.kind, kind: payload[:kind].presence || item.kind }
    resolved[:agenda_schedule_id] = item.agenda_schedule_id if series
    # Resolved HERE rather than at execute so the row shows the time that
    # actually lands. This is the call that put a shower at 4:45 AM under a
    # reply announcing 4:45 PM — see ToolContext#resolve_calendar_time.
    resolved[:at] = ctx.resolve_calendar_time(payload[:at]) if payload[:at].present?

    # A leave time is not a start time, and the difference is the drive. The
    # app knows `travel_seconds` and `arrive_early_minutes`; the model does not,
    # and when it guessed it was 12 minutes out (prod 5145). So it is worked
    # back HERE and the start is what gets written.
    #
    # Refused rather than guessed when there is no drive time on the row - a
    # virtual meeting, somewhere with no location, or an item the chain has not
    # reached yet. Silently treating a leave time as a start is exactly the
    # mistake this argument exists to stop.
    if payload[:leave_at].present?
      raise "give me either a start (`at`) or a leave time (`leave_at`), not both" if payload[:at].present?

      leave  = ctx.resolve_calendar_time(payload[:leave_at])
      drive  = item.metadata.dig("travel", "travel_seconds").to_i
      early  = item.arrive_early_minutes.to_i * 60
      if drive.zero?
        raise "I don't have a drive time for #{item.name}, so I can't work back from a leave time - " \
              "ask whether they meant the start instead"
      end

      resolved[:at]         = leave + drive + early
      resolved[:leave_from] = leave
      resolved[:drive_secs] = drive
    end
    if payload[:calendar].present?
      # resolve_writable_agenda only ever returns LOCAL calendars the person can
      # write to, so the destination needs no Google guard of its own. `strict`
      # because the loose form falls back to their default, and silently moving
      # something to a calendar nobody named is worse than refusing.
      target = ctx.resolve_writable_agenda(payload[:calendar], strict: true)
      raise "no calendar named #{payload[:calendar].inspect} that you can write to" if target.nil?

      resolved[:agenda_id]   = target.id
      resolved[:agenda_name] = target.name
      resolved[:agenda_from] = item.agenda.name
    end

    { summary: "Edit #{item.name}?", resolved: resolved }
  },
  label:       ->(payload, ctx) {
    item = AgendaItem.find_by(id: payload[:agenda_item_id])
    base = item&.name || payload[:item].to_s
    diffs = []
    diffs << "title → #{payload[:title]}" if payload[:title].present?
    # BOTH times when they asked to leave at one. Naming only the start reads
    # as though their leave time was ignored, and naming only the leave time is
    # what put "leave at 4:28" on a 4:28 start (prod 5147).
    if payload[:leave_from].respond_to?(:strftime) && payload[:at].respond_to?(:strftime)
      zone = ctx.user.timezone
      diffs << "leave #{payload[:leave_from].in_time_zone(zone).strftime("%-I:%M %p")} → " \
               "starts #{payload[:at].in_time_zone(zone).strftime("%a %-I:%M %p")}"
    elsif payload[:at].respond_to?(:strftime)
      diffs << "time → #{payload[:at].in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p")}"
    end
    diffs << "duration → #{payload[:duration]}m" if payload[:duration].present?
    diffs << "@ #{payload[:location]}" if payload[:location].present?
    diffs << "📅 #{payload[:agenda_from]} → #{payload[:agenda_name]}" if payload[:agenda_name].present?
    diffs << "#{payload[:was_kind]} → #{payload[:kind]}" if payload[:kind].to_s != payload[:was_kind].to_s
    diffs << "cancel" if payload[:cancelled] == "true"
    { title: base, sub: diffs.join("\n").presence }
  },
  # Level 2, like the add: the change lands as a pre-checked row that unticks
  # back off. `before` below snapshots every field being written, so the undo
  # restores exactly what was there.
  level:       2,
  execute:     ->(payload, ctx) {
    next Buddy::AgendaSeriesEdit.call(payload, ctx) if payload[:agenda_schedule_id].present?

    item = AgendaItem.find(payload[:agenda_item_id])
    attrs = {}
    attrs[:name]      = payload[:title]     if payload[:title].present?
    attrs[:location]  = payload[:location]  if payload[:location].present?
    # Reassigning agenda_id IS the move. Undo comes free: `before` below snapshots
    # every attr being written, so Reverter#revert_update puts it back.
    attrs[:agenda_id] = payload[:agenda_id] if payload[:agenda_id].present?
    # `at` is an ISO string at execute time (JSON round-trip) — parse it.
    new_start = payload[:at].present? ? ctx.resolve_time(payload[:at]) : nil
    attrs[:start_at] = new_start if new_start
    # What it's becoming, which is what it already is unless they asked for a
    # conversion. Every span decision below is about the TARGET kind: a to-do
    # being made into an event needs the span it has never had.
    becoming = (payload[:kind].presence || item.kind).to_s
    attrs[:kind] = becoming if becoming != item.kind

    # Only an event has a span. A task's end_at is nil and must stay nil, or the
    # row starts rendering as a time range it doesn't actually occupy.
    if becoming == "event"
      base_start = attrs[:start_at] || item.start_at
      minutes = payload[:duration].presence&.to_i
      # Moving an event's start without a new duration keeps the old length —
      # otherwise end_at stays put and a move later in the day fails the
      # end-after-start validation.
      minutes ||= ((item.end_at - item.start_at) / 60).round if new_start && item.end_at.present?
      # A task has no length to carry over, so a conversion that named none
      # takes the same 30 minutes add_agenda_item gives a new event.
      minutes ||= 30 if item.end_at.blank?
      attrs[:end_at] = base_start + minutes.minutes if minutes
    elsif item.end_at.present?
      # Becoming a to-do: the span goes, rather than lingering as a range the
      # row no longer renders.
      attrs[:end_at] = nil
    end
    attrs[:status] = :cancelled if payload[:cancelled] == "true"
    prior_name = item.name
    before     = attrs.keys.index_with { |k| item.public_send(k) }  # old values, for undo
    item.update!(attrs) unless attrs.empty?
    {
      agenda_item_id: item.id,
      updated_fields: attrs.keys,
      # Carried so the receipt can say the time they actually named. Without
      # it the confirmation talks only about a start they never mentioned.
      leave_from:     payload[:leave_from],
      revert:         { op: "updated", model: "AgendaItem", id: item.id, before: before, summary: "reverted #{prior_name}" },
    }
  },
  receipt:     ->(result, ctx) {
    next Buddy::AgendaSeriesEdit.receipt(result, ctx) if result[:agenda_schedule_id].present?

    item   = AgendaItem.find_by(id: result[:agenda_item_id])
    name   = item&.name || "that item"
    fields = Array(result[:updated_fields]).map(&:to_s)
    return "Moved #{name} to #{item&.agenda&.name} ✓" if fields.include?("agenda_id")
    # The conversion IS the change worth reporting, and for an event the length
    # is the half of it they'll want to see.
    if fields.include?("kind") && item
      span = ("#{((item.end_at - item.start_at) / 60).round}m" if item.event? && item.end_at)
      return ["#{name} is #{item.event? ? "an" : "a"} #{item.kind} now", span].compact.join(" - ") + " ✓"
    end
    # When the change IS the time, say the time. A bare "Updated Shower ✓" sat
    # under a reply claiming 4:45 PM while the row went to 4:45 AM, and nothing
    # on screen disagreed with the sentence.
    return "Updated #{name} ✓" unless fields.include?("start_at") && item&.start_at

    zone  = ctx.user.timezone
    start = item.start_at.in_time_zone(zone).strftime("%a %-I:%M %p")
    # They asked to LEAVE at a time, so lead with that - it is the half they
    # said and the half they act on. The start is the consequence.
    leave = (ctx.resolve_time(result[:leave_from]) if result[:leave_from].present?)
    return "#{name} - leave #{leave.in_time_zone(zone).strftime("%-I:%M %p")}, starts #{start} ✓" if leave

    "#{name} → #{start} ✓"
  },
)
