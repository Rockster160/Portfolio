Buddy::Tools.register(
  name:        :add_agenda_item,
  description: <<~TXT,
    Add a new item to the user's calendar/agenda. Use for appointments,
    events, or tasks. `at` is an ISO datetime. `duration` is in minutes.
    `kind` is one of: event, task, trigger - use `event` for anything that
    happens over a span of time (a hike, a dinner, an appointment); `task`
    for a to-do, which sits at ONE time and has no duration at all.

    If they said "agenda" or "calendar", this is the tool. A to-do they want
    on the agenda is `kind: task` here, not a reminder and not a list item.
    No time named? Pick the natural one (now, for "once I get home"; tonight,
    for "later") and say what you assumed - don't stall the add to ask.

    Pull the PLACE into `location`, not the title: "coffee at Lucky Ones"
    → title "Coffee", location "Lucky Ones". "dentist" with no place →
    no location.

    `duration`: EVENTS only - set it to the activity's actual length, don't
    leave the 30m default on something clearly longer. If your memory or the
    person tells you how long a thing runs (e.g. "the plunge is ~2 hours"),
    use that. It's ignored on a task; tasks are a single moment.

    `calendar`: which calendar to add to, by name ("Ours", "Tasks", etc.).
    Matches the person's own + shared-editable LOCAL calendars. Omit for
    their default. (Google-synced calendars still need the app's add flow.)

    `repeat` makes it a SERIES instead of a single row - "check the flower bed
    every day", "trash out every Wednesday", "pay rent on the 1st". Same specs
    `schedule_reminder` takes, and the clock is optional here since `at`
    already carries one:
      "daily" / "daily:HH:MM"          - every day
      "weekdays"                       - Mon-Fri
      "weekly:<days>"                  - "weekly:wednesday", "weekly:mon,wed,fri"
      "monthly:<day-of-month>"         - "monthly:1" is the 1st
      "monthly:<nth>-<weekday>"        - "monthly:2-tuesday" is the SECOND
                                         TUESDAY of each month
      "every:<n>-<unit>"               - "every:2-weeks" is every other week
      "yearly"                         - once a year, on `at`'s date
    `at` sets when the series STARTS and what time of day each one lands.
    `until` (YYYY-MM-DD) stops it after that day.

    A repeating agenda task is SILENT - it appears on the calendar and waits to
    be looked at. If they need to be TOLD each time, a recurring reminder is
    what actually reaches them, and for someone who lives out of their
    reminders rather than their calendar that's most things. Setting both is
    fine and often right: the series is the record, the reminder is the nudge.

    ONLY for something that doesn't exist yet. If they're talking about an
    item that's already on a calendar - moving it, renaming it, changing its
    time or place - that's `edit_agenda_item`, including when the change is
    which calendar it lives on. Adding in that situation doesn't move
    anything; it leaves the original where it was and gives them two.
  TXT
  feature:     :agenda,
  args:        {
    title:    { type: :string,       required: true,  description: "What is it (the activity, WITHOUT the place)" },
    at:       { type: :iso_time,     required: true,  description: "Local wall-clock start, 24-hour. Something happening today goes AHEAD of the current time" },
    duration: { type: :duration_min, required: false, default: 30, description: "Minutes - the activity's real length, not always 30. Events only; ignored on a task" },
    location: { type: :string,       required: false, description: "Place/venue/address, if one was mentioned" },
    kind:     { type: :enum,         required: false, default: :event, values: %i[event task trigger] },
    all_day:  { type: :string,       required: false, description: "'true' for all-day" },
    calendar: { type: :string,       required: false, description: "Which calendar/agenda to add to, by name (e.g. 'Ours'); omit for default" },
    repeat:   { type: :string,       required: false, description: "Recurrence spec, making this a series: daily / weekdays / weekly:<days> / monthly:<dom> / monthly:<nth>-<weekday> / every:<n>-<unit> / yearly" },
    until:    { type: :string,       required: false, description: "Stop repeating after this date (YYYY-MM-DD)" },
  },
  confirm:     ->(payload, ctx) {
    agenda = ctx.resolve_writable_agenda(payload[:calendar])
    raise "no writable calendar available" if agenda.nil?

    start = ctx.resolve_calendar_time(payload[:at])
    raise "couldn't work out when to start" if start.nil?

    local      = start.in_time_zone(ctx.user.timezone)
    repeat     = payload[:repeat].to_s.strip
    recurrence = nil
    if repeat.present?
      recurrence = Buddy::RepeatSpec.parse(Buddy::RepeatSpec.with_clock(repeat, local), on: local.to_date)
      raise "unknown repeat spec #{payload[:repeat].inspect}" if recurrence.nil?

      if payload[:until].to_s.strip.present?
        ends = (Date.parse(payload[:until].to_s) rescue nil)
        raise "couldn't read #{payload[:until].inspect} as a date" if ends.nil?

        recurrence = recurrence.merge("until_on" => ends.iso8601)
      end
    end

    is_default = agenda.id == ctx.default_agenda&.id
    # Prod 1201: "move it to Ours" produced an ADD, so the same Costco Run now
    # exists twice at 1:00 PM. The description covers it, but description alone
    # is what already failed, so look for the item they probably meant to move.
    #
    # Deliberately a note rather than a raise: two genuinely separate errands can
    # collide, and refusing a real add is worse than a duplicate. This runs in
    # Turn.resolve_call BEFORE the model writes a word, so being told is enough —
    # it can switch to edit_agenda_item in the same turn.
    twin = ctx.existing_agenda_twin(payload[:title], payload[:at])
    warning = twin && "#{twin.name} already exists at that time on #{twin.agenda.name}. " \
                      "If they meant to MOVE it, use edit_agenda_item with calendar instead - " \
                      "adding leaves the original in place and makes a second one."

    {
      summary:  ["Add #{payload[:title]} to #{agenda.name}?", warning].compact.join(" "),
      # `at` is resolved HERE, not at execute, so the checklist row renders the
      # same time that lands on the calendar. See resolve_calendar_time: a
      # same-day time that's already past is the 12-hour slip, and the row is
      # where it has to be visible.
      resolved: {
        agenda_id:      agenda.id,
        agenda_name:    agenda.name,
        agenda_default: is_default,
        at:             start,
        recurrence:     recurrence,
      }.compact,
    }
  },
  # The confirm card is for a HUMAN to review, so favour readability: one
  # non-default detail per line, no word-labels where a symbol or the value
  # itself already says what it is. Default calendar / no location just don't
  # get a line.
  label:       ->(payload, ctx) {
    start   = payload[:at].respond_to?(:in_time_zone) ? payload[:at].in_time_zone(ctx.user.timezone) : nil
    all_day = payload[:all_day].to_s == "true"

    # When — one temporal line. Events get a start–end range so the duration is
    # self-evident; a task has no end, so showing "2:49–3:19 PM" on one would be
    # inventing a span the row will never have.
    when_line =
      if start.nil?
        payload[:at].to_s
      elsif all_day
        start.strftime("%a %b %-d, all day")
      elsif payload[:kind].to_s != "event"
        "#{start.strftime("%a %b %-d")}, #{start.strftime("%-I:%M %p")}"
      else
        dur    = payload[:duration].to_i
        dur    = 30 if dur <= 0
        finish = start + dur.minutes
        "#{start.strftime("%a %b %-d")}, #{start.strftime("%-I:%M %p")}–#{finish.strftime("%-I:%M %p")}"
      end

    lines = [when_line]
    if payload[:recurrence].present?
      lines << "🔁 #{Buddy::ReminderPresenter.repeat_phrase(payload[:recurrence])}"
    end
    lines << "@ #{payload[:location]}" if payload[:location].present?  # place — @ says it's a location
    # Calendar — only when it's NOT the default (a non-default detail worth
    # calling out); 📅 marks it as a calendar without a word-label.
    lines << "📅 #{payload[:agenda_name]}" if payload[:agenda_name].present? && !payload[:agenda_default]

    { title: payload[:title].to_s, sub: lines.join("\n") }
  },
  # Level 2: goes on the calendar the moment it's proposed, as a pre-checked row
  # that unchecks back off. Putting something on a calendar is easy to see and
  # easy to take back (the revert below cancels the item), so making them tap to
  # confirm every add was a toll on the common case — they'd already said what
  # they wanted. The row is the receipt AND the undo.
  level:       2,
  execute:     ->(payload, ctx) {
    agenda = Agenda.find(payload[:agenda_id])
    # `at` arrives here as an ISO STRING (the payload was JSON-serialized onto
    # the ByteAction between build and execute), so parse it back to a Time.
    start_at = ctx.resolve_time(payload[:at])
    raise "couldn't parse the start time" if start_at.nil?

    kind = (payload[:kind].presence || :event).to_sym
    duration = payload[:duration].to_i
    duration = 30 if duration <= 0

    attrs = {
      name:     payload[:title],
      location: payload[:location].presence,
      start_at: start_at,
      # Only an event occupies a span. `end_at` is required for events and
      # optional for everything else (see AgendaItem validations), and a task
      # carrying one renders as a time RANGE - "Shower, 2:49-3:19 PM" - which
      # reads like a scheduled block instead of the single-moment to-do it is.
      end_at:   (start_at + duration.minutes if kind == :event),
      all_day:  payload[:all_day].to_s == "true",
      kind:     kind,
      status:   :confirmed,
    }
    # Arrive 5 minutes early for anything with a place to be, so the travel /
    # leave-by chain builds in a small buffer. No location → leave the column's
    # default (0) alone (it's NOT NULL).
    attrs[:arrive_early_minutes] = 5 if payload[:location].present?

    # A repeat is a SERIES, not a row: AgendaSchedule owns the rule and
    # materializes occurrences forward on save (and rolls the window on from
    # there), so creating one is all that's needed. Its items are `dependent:
    # :destroy`, which is what makes the undo below clean.
    if payload[:recurrence].present?
      schedule = Buddy::AgendaSeries.create!(agenda, payload[:recurrence], attrs, duration: duration)
      next {
        agenda_schedule_id: schedule.id,
        recurrence:         payload[:recurrence],
        revert:             {
          op: "created", model: "AgendaSchedule", id: schedule.id, summary: "removed #{schedule.name}"
        },
      }
    end

    item = agenda.agenda_items.create!(attrs)
    {
      agenda_item_id: item.id,
      revert:         { op: "created", model: "AgendaItem", id: item.id, summary: "removed #{item.name}" },
    }
  },
  receipt:     ->(result, ctx) {
    if result[:agenda_schedule_id]
      schedule = AgendaSchedule.find_by(id: result[:agenda_schedule_id])
      phrase   = Buddy::ReminderPresenter.repeat_phrase(result[:recurrence])
      next "Added #{schedule&.name || "that"} #{phrase} to #{schedule&.agenda&.name || "your calendar"} ✓"
    end

    item  = AgendaItem.find_by(id: result[:agenda_item_id])
    where = item&.agenda&.name.presence
    start = item&.start_at&.in_time_zone(ctx.user.timezone)
    when_ = start&.strftime("%a %-I:%M %p")
    # The time is the half most worth reading back. Without it the receipt
    # agreed with a reply that said "later this afternoon" while the row went
    # on at 4:45 AM.
    ["Added #{item&.name || "that"}", ("at #{when_}" if when_), "to #{where || "your calendar"} ✓"].compact.join(" ")
  },
)
