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

    For v1, only edits local (non-Google-synced) items.
  TXT
  args:        {
    item:      { type: :string,       required: true,  description: "Fuzzy title of the item to edit" },
    hint_date: { type: :string,       required: false, description: "Date hint (YYYY-MM-DD) for disambiguation" },
    title:     { type: :string,       required: false, description: "New title" },
    at:        { type: :iso_time,     required: false, description: "New start time (ISO)" },
    duration:  { type: :duration_min, required: false, description: "New duration in minutes" },
    location:  { type: :string,       required: false, description: "New place/venue" },
    calendar:  { type: :string,       required: false, description: "Move it to this calendar, by name (e.g. 'Ours')" },
    cancelled: { type: :string,       required: false, description: "'true' to cancel" },
  },
  confirm:     ->(payload, ctx) {
    item = ctx.resolve_agenda_item(payload[:item], hint_date: payload[:hint_date])
    raise "no agenda item matching #{payload[:item].inspect}" if item.nil?
    raise "cannot edit Google-synced items yet" if item.agenda.managed_externally?

    resolved = { agenda_item_id: item.id }
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
    diffs << "cancel" if payload[:cancelled] == "true"
    { title: base, sub: diffs.join("\n").presence }
  },
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
    # Only an event has a span. A task's end_at is nil and must stay nil, or the
    # row starts rendering as a time range it doesn't actually occupy.
    if item.event?
      base_start = attrs[:start_at] || item.start_at
      minutes = payload[:duration].presence&.to_i
      # Moving an event's start without a new duration keeps the old length —
      # otherwise end_at stays put and a move later in the day fails the
      # end-after-start validation.
      minutes ||= ((item.end_at - item.start_at) / 60).round if new_start && item.end_at.present?
      attrs[:end_at] = base_start + minutes.minutes if minutes
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
  receipt:     ->(result, _ctx) {
    item  = AgendaItem.find_by(id: result[:agenda_item_id])
    name  = item&.name || "that item"
    moved = Array(result[:updated_fields]).map(&:to_s).include?("agenda_id")
    moved ? "Moved #{name} to #{item&.agenda&.name} ✓" : "Updated #{name} ✓"
  },
)
