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

    **A weekday whose time has already gone today means NEXT week.** "Dinner
    with Sam Thursday at 7", said at nine on a Thursday evening, is next
    Thursday - nobody schedules a thing for two hours ago. Add it there and
    say which Thursday you took it for. Asked instead ("has already gone by
    tonight, so I need to know if you mean next Thursday") it costs them a
    whole extra exchange to confirm the only reading that made sense.

    Pull the PLACE into `location`, not the title: "coffee at Lucky Ones"
    → title "Coffee", location "Lucky Ones". "dentist" with no place →
    no location.

    `duration`: EVENTS only - set it to the activity's actual length, don't
    leave the 30m default on something clearly longer. If the household's own
    words, your memory, or the person tells you how long a thing runs, use
    that. It's ignored on a task; tasks are a single moment.

    **"LEAVE at 4:15" IS NOT "start at 4:15" - use `leave_at`, never `at`.**
    For anywhere with a drive, the time they say out loud is often the one they
    walk out of the door, and `at` is always the START. Pass `leave_at` and the
    start is worked back from the drive and how early they like to arrive -
    which is arithmetic this app HAS and you do not. Never both in one call, and
    never do the sum yourself: "Add Insidious movie today, leaving at 4:15"
    became a 4:40 start with `arrive_early: 25` and no drive time anywhere in
    the 25 (prod 5935-5939). A leave time needs somewhere to drive TO, so pass
    `location` with it.

    **"Let's be 10 minutes early" is `arrive_early`, and nothing else.** It is a
    plain number of minutes on the row, it needs no drive time and no address,
    and it is what the app's own "min early" setting holds. Leave it out and
    they get 5, which is the default a person means by not saying. Asked to
    "add an Eye Follow Up tomorrow at 11:40, and let's be 10 minutes early",
    the reply added it and then asked whether 11:40 was the check-in or the
    appointment (prod 5338-5339) - there was no argument to put the 10 in.

    **They said nothing about a buffer? Then the argument isn't in the call.**
    Not a filled-in one, not a stated absence - out. A buffer nobody named is
    an OMISSION, and only an omission reaches the setting they chose for
    themselves; anything passed here overrides it with a guess (prod 5725).

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
    title:        { type: :string,       required: true,  description: "What is it (the activity, WITHOUT the place)" },
    at:           { type: :iso_time,     required: false, description: "Local wall-clock START, 24-hour. Something happening today goes AHEAD of the current time. If they said LEAVE, use `leave_at` instead" },
    leave_at:     { type: :iso_time,     required: false, description: "The time they want to LEAVE, 24-hour local, INSTEAD of `at`. The start is worked back from the drive and the arrive-early minutes. Needs a `location` to drive to. Never pass this together with `at`" },
    duration:     { type: :duration_min, required: false, default: 30, description: "Minutes - the activity's real length, not always 30. Events only; ignored on a task" },
    location:     { type: :string,       required: false, description: "Place/venue/address, if one was mentioned" },
    arrive_early: {
      type:        :duration_min,
      required:    false,
      # No worked example of "they don't want a buffer" here on purpose. This
      # read "or 0 for 'no need to be early'" until prod 5725, where "Add a
      # Plunge with Christian today leaving at 4" - which says nothing about
      # arriving at all - came back carrying `arrive_early: 0`. It was the only
      # concrete value the description offered, so it got reached for, and it
      # defeated the default the branch below exists to protect. An option
      # spelled out in an argument description is a suggestion to use it.
      description: "Minutes to be there BEFORE it starts. Only when they NAMED one out loud " \
                   "(\"let's be 10 minutes early\") - otherwise omit the argument entirely and " \
                   "they get #{AgendaItem::DEFAULT_ARRIVE_EARLY_MINUTES}, which is the setting they chose",
    },
    kind:         { type: :enum,         required: false, default: :event, values: %i[event task trigger] },
    all_day:      { type: :string,       required: false, description: "'true' for all-day" },
    calendar:     { type: :string,       required: false, description: "Which calendar/agenda to add to, by name (e.g. 'Ours'); omit for default" },
    repeat:       { type: :string,       required: false, description: "Recurrence spec, making this a series: daily / weekdays / weekly:<days> / monthly:<dom> / monthly:<nth>-<weekday> / every:<n>-<unit> / yearly" },
    until:        { type: :string,       required: false, description: "Stop repeating after this date (YYYY-MM-DD)" },
  },
  confirm:     ->(payload, ctx) {
    # `strict` for the same reason edit_agenda_item uses it. The loose form
    # falls back to the default calendar, and the argument that it is catchable
    # on the confirm card lost on prod 4463: five dinners asked for on a
    # "Dinners" calendar that does not exist landed on Alchemibluum, and the
    # reply said Dinners because that is what the model had passed. A raise is
    # recoverable in the same turn - 4465 did exactly that forty seconds later
    # against the strict edit path - and a silent landing is not.
    agenda = ctx.resolve_writable_agenda(payload[:calendar], strict: true)
    raise "no writable calendar available" if agenda.nil? && payload[:calendar].blank?
    raise "no calendar named #{payload[:calendar].inspect} that you can write to" if agenda.nil?

    # A leave time is not a start time, and the difference is the drive. The
    # same rule edit_agenda_item has carried since prod 5145, for the same
    # reason: asked for a leave time the model does the sum in its head, and
    # when it did it here the whole drive went missing (prod 5935-5939).
    #
    # Worked back HERE rather than at execute so the row on the card shows the
    # start that actually lands, and so a drive it can't measure is a raise the
    # model can still answer - once the item exists there is nothing to do about
    # it but leave the leave time silently treated as a start.
    leave_from = nil
    if payload[:leave_at].present?
      raise "give me either a start (`at`) or a leave time (`leave_at`), not both" if payload[:at].present?
      raise "a leave time needs somewhere to drive to - pass `location` too, or ask whether they meant the start" if payload[:location].blank?

      leave_from = ctx.resolve_calendar_time(payload[:leave_at])
      raise "couldn't work out when they want to leave" if leave_from.nil?

      drive = ctx.drive_seconds_to(payload[:location], at: leave_from).to_i
      if drive.zero?
        raise "I can't work out the drive to #{payload[:location]}, so I can't work back from a " \
              "leave time - ask whether they meant the start instead. If what they actually asked " \
              "for was to be there a few minutes EARLY, that's `arrive_early` and it needs no drive"
      end

      # The buffer they NAMED, or the setting they chose for themselves - never
      # a number invented to make the clock land. See `arrive_early` below.
      early = (payload[:arrive_early].presence || AgendaItem::DEFAULT_ARRIVE_EARLY_MINUTES).to_i
      start = leave_from + drive + (early * 60)
    else
      # `at` stopped being a required argument the moment `leave_at` could stand
      # in for it, so the schema no longer catches a call carrying neither.
      raise "give me a start (`at`) or a leave time (`leave_at`)" if payload[:at].blank?

      start = ctx.resolve_calendar_time(payload[:at])
    end
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
    twin = ctx.existing_agenda_twin(payload[:title], start)
    warning = twin && "#{twin.name} already exists at that time on #{twin.agenda.name}. " \
                      "If they meant to MOVE it, use edit_agenda_item with calendar instead - " \
                      "adding leaves the original in place and makes a second one."

    {
      summary:  ["Add #{payload[:title]} to #{agenda.name}?", warning].compact.join(" "),
      # `at` is resolved HERE, not at execute, so the checklist row renders the
      # same time that lands on the calendar. See resolve_calendar_time: an hour
      # already gone today resolves to now, and the row is where that has to be
      # visible before it's agreed to.
      resolved: {
        agenda_id:      agenda.id,
        agenda_name:    agenda.name,
        agenda_default: is_default,
        at:             start,
        leave_from:     leave_from,
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
        Buddy::Clock.date_at(start)
      else
        dur    = payload[:duration].to_i
        dur    = 30 if dur <= 0
        finish = start + dur.minutes
        "#{start.strftime("%a %b %-d")}, #{Buddy::Clock.range(start, finish)}"
      end

    # The leave time is the thing they ASKED for, and the start is what the app
    # worked out from it. Showing only the start makes the card look like an
    # answer to a question nobody asked - edit_agenda_item's row says
    # "leave 4:15 PM -> starts Fri 4:40 PM" for the same reason.
    if payload[:leave_from].present?
      leave     = payload[:leave_from]
      leave     = leave.in_time_zone(ctx.user.timezone) if leave.respond_to?(:in_time_zone)
      when_line = "leave #{Buddy::Clock.at(leave)} → #{when_line}"
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
  # Asked once the calendar and the start are resolved, so it knows exactly which
  # row would be written. See Buddy::AgendaDuplicate.
  #
  # A `repeat` is exempt: it writes an AgendaSchedule rather than a row, and its
  # occurrences are materialized by the series, so there is no single start to
  # compare. `existing_agenda_twin`'s note still covers that case.
  guard:       ->(payload, ctx) {
    next if payload[:recurrence].present?

    Buddy::AgendaDuplicate.check!(
      payload[:agenda_id],
      payload[:title],
      payload[:at],
      zone: ctx.user.timezone,
    )
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
    # Five minutes early unless they said otherwise, place or no place.
    #
    # It used to be five ONLY with a location, on the reasoning that there is
    # no travel to be early for otherwise - so "add Jake's birthday at 6" got a
    # zero, and so did every appointment whose address nobody mentioned out
    # loud. From the person's side that is Buddy overwriting the setting rather
    # than declining to guess at it. An explicit 0 still means 0: `present?` is
    # true of it, which is the whole reason this reads the key rather than
    # `.presence`.
    #
    # What changed after prod 5725 is upstream, not here: the argument no
    # longer SHOWS the model a 0, so the branch is reached by a buffer somebody
    # actually named rather than by the one value the description happened to
    # spell out.
    attrs[:arrive_early_minutes] = (
      payload[:arrive_early].present? ? payload[:arrive_early].to_i : AgendaItem::DEFAULT_ARRIVE_EARLY_MINUTES
    )

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
    when_ = Buddy::Clock.day_at(start)
    # The time is the half most worth reading back. Without it the receipt
    # agreed with a reply that said "later this afternoon" while the row went
    # on at 4:45 AM.
    ["Added #{item&.name || "that"}", ("at #{when_}" if when_), "to #{where || "your calendar"} ✓"].compact.join(" ")
  },
)
