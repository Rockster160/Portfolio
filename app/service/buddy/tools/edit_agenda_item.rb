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

    For v1, only edits local (non-Google-synced) items.
  TXT
  feature:     :agenda,
  args:        {
    item:      { type: :string,       required: true,  description: "Fuzzy title of the item to edit" },
    hint_date: { type: :string,       required: false, description: "Date hint (YYYY-MM-DD) for disambiguation" },
    title:     { type: :string,       required: false, description: "New title" },
    at:        { type: :iso_time,     required: false, description: "New local wall-clock start, 24-hour. Moving something on today's calendar puts it AHEAD of the current time" },
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

    # `was_kind` is what the row IS, carried so the checklist can say "Edit
    # Task" rather than "Edit Event" on a to-do. `kind` is what it's BECOMING,
    # which is the same thing unless they asked to convert it.
    resolved = { agenda_item_id: item.id, was_kind: item.kind, kind: payload[:kind].presence || item.kind }
    # Resolved HERE rather than at execute so the row shows the time that
    # actually lands. This is the call that put a shower at 4:45 AM under a
    # reply announcing 4:45 PM — see ToolContext#resolve_calendar_time.
    resolved[:at] = ctx.resolve_calendar_time(payload[:at]) if payload[:at].present?
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
    diffs << "time → #{payload[:at].in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p")}" if payload[:at].respond_to?(:strftime)
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
      revert:         { op: "updated", model: "AgendaItem", id: item.id, before: before, summary: "reverted #{prior_name}" },
    }
  },
  receipt:     ->(result, ctx) {
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

    "#{name} → #{item.start_at.in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p")} ✓"
  },
)
