Buddy::Tools.register(
  name:        :add_agenda_item,
  description: <<~TXT,
    Add a new item to the user's calendar/agenda. Use for appointments,
    events, or tasks. `at` is an ISO datetime. `duration` is in minutes.
    `kind` is one of: event, task, trigger - use `event` for anything that
    happens over a span of time (a hike, a dinner, an appointment); `task`
    only for a to-do with no real duration.

    Pull the PLACE into `location`, not the title: "coffee at Lucky Ones"
    → title "Coffee", location "Lucky Ones". "dentist" with no place →
    no location.

    `duration`: set it to the activity's actual length - don't leave the 30m
    default on something clearly longer. If your memory or the person tells
    you how long a thing runs (e.g. "the plunge is ~2 hours"), use that.

    `calendar`: which calendar to add to, by name ("Ours", "Tasks", etc.).
    Matches the person's own + shared-editable LOCAL calendars. Omit for
    their default. (Google-synced calendars still need the app's add flow.)

    ONLY for something that doesn't exist yet. If they're talking about an
    item that's already on a calendar - moving it, renaming it, changing its
    time or place - that's `edit_agenda_item`, including when the change is
    which calendar it lives on. Adding in that situation doesn't move
    anything; it leaves the original where it was and gives them two.
  TXT
  args:        {
    title:    { type: :string,       required: true,  description: "What is it (the activity, WITHOUT the place)" },
    at:       { type: :iso_time,     required: true,  description: "ISO datetime with timezone offset" },
    duration: { type: :duration_min, required: false, default: 30, description: "Minutes - the activity's real length, not always 30" },
    location: { type: :string,       required: false, description: "Place/venue/address, if one was mentioned" },
    kind:     { type: :enum,         required: false, default: :event, values: %i[event task trigger] },
    all_day:  { type: :string,       required: false, description: "'true' for all-day" },
    calendar: { type: :string,       required: false, description: "Which calendar/agenda to add to, by name (e.g. 'Ours'); omit for default" },
  },
  confirm:     ->(payload, ctx) {
    agenda = ctx.resolve_writable_agenda(payload[:calendar])
    raise "no writable calendar available" if agenda.nil?

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
      resolved: { agenda_id: agenda.id, agenda_name: agenda.name, agenda_default: is_default },
    }
  },
  # The confirm card is for a HUMAN to review, so favour readability: one
  # non-default detail per line, no word-labels where a symbol or the value
  # itself already says what it is. Default calendar / no location just don't
  # get a line.
  label:       ->(payload, ctx) {
    start   = payload[:at].respond_to?(:in_time_zone) ? payload[:at].in_time_zone(ctx.user.timezone) : nil
    all_day = payload[:all_day].to_s == "true"

    # When — one temporal line, a start–end range so the duration is self-evident.
    when_line =
      if start.nil?
        payload[:at].to_s
      elsif all_day
        start.strftime("%a %b %-d, all day")
      else
        dur    = payload[:duration].to_i
        dur    = 30 if dur <= 0
        finish = start + dur.minutes
        "#{start.strftime("%a %b %-d")}, #{start.strftime("%-I:%M %p")}–#{finish.strftime("%-I:%M %p")}"
      end

    lines = [when_line]
    lines << "@ #{payload[:location]}" if payload[:location].present?  # place — @ says it's a location
    # Calendar — only when it's NOT the default (a non-default detail worth
    # calling out); 📅 marks it as a calendar without a word-label.
    lines << "📅 #{payload[:agenda_name]}" if payload[:agenda_name].present? && !payload[:agenda_default]

    { title: payload[:title].to_s, sub: lines.join("\n") }
  },
  execute:     ->(payload, ctx) {
    agenda = Agenda.find(payload[:agenda_id])
    # `at` arrives here as an ISO STRING (the payload was JSON-serialized onto
    # the ByteAction between build and execute), so parse it back to a Time.
    start_at = ctx.resolve_time(payload[:at])
    raise "couldn't parse the start time" if start_at.nil?

    duration = payload[:duration].to_i
    duration = 30 if duration <= 0
    end_at   = start_at + duration.minutes

    attrs = {
      name:     payload[:title],
      location: payload[:location].presence,
      start_at: start_at,
      end_at:   end_at,
      all_day:  payload[:all_day].to_s == "true",
      kind:     payload[:kind] || :event,
      status:   :confirmed,
    }
    # Arrive 5 minutes early for anything with a place to be, so the travel /
    # leave-by chain builds in a small buffer. No location → leave the column's
    # default (0) alone (it's NOT NULL).
    attrs[:arrive_early_minutes] = 5 if payload[:location].present?

    item = agenda.agenda_items.create!(attrs)
    {
      agenda_item_id: item.id,
      revert:         { op: "created", model: "AgendaItem", id: item.id, summary: "removed #{item.name}" },
    }
  },
  receipt:     ->(result, _ctx) {
    item = AgendaItem.find_by(id: result[:agenda_item_id])
    where = item&.agenda&.name.presence
    "Added #{item&.name || "that"} to #{where || "your calendar"} ✓"
  },
)
