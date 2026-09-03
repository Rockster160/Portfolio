Buddy::Tools.register(
  name:        :check_travel_time,
  description: <<~TXT,
    Work out the drive for something on the calendar: how long it takes to get
    there, what time to walk out of the door, and what time they are back home
    afterwards. Reads it if it's already known and goes and measures it if it
    isn't.

    **Call this when you need a number you haven't got.** `edit_agenda_item`
    refuses a `leave_at` on an item with no drive time rather than guessing one,
    and something Buddy has only just created has no drive time yet - this is
    how that gets unstuck, in the same turn, without asking them anything. Asked
    to move an event so they could leave at 4, a companion said "I don't have a
    drive time for that" and stopped, on an event it had itself put on the
    calendar ninety seconds earlier (prod 5268).

    Also for "how far is that", "how long will it take me to get there", "when
    do I need to leave", "when will I be home".

    **`follow_on` is the answer to "line the next thing up behind it".** It is
    the time they are through their own front door, given a few minutes to
    actually arrive, rounded to something a person would say out loud. Use it as
    the `at` or `leave_at` of the thing that comes next rather than doing the
    arithmetic yourself - "leave once she's back from yoga" is `leave_at` set to
    the yoga's `follow_on`.

    Somebody else's item is fine to look up. Their drive home is a fact about
    when the house is theirs again, which is a fact about the asker's day.

    If there's no location on it, or nowhere the address can be found, this says
    so plainly. That is a real answer - tell them, rather than inventing a
    figure.
  TXT
  feature:     :agenda,
  args:        {
    item:      { type: :string, required: true,  description: "Fuzzy title of the calendar item to measure" },
    hint_date: { type: :string, required: false, description: "Date hint (YYYY-MM-DD) for disambiguation" },
  },
  # A read. Nothing is written but the travel figures on the row itself, which
  # is a cache of something already true.
  auto:        true,
  answers:     true,
  confirm:     ->(payload, ctx) {
    item = ctx.resolve_agenda_item(payload[:item], hint_date: payload[:hint_date], editable: false)
    raise "no agenda item matching #{payload[:item].inspect}" if item.nil?

    if item.location.to_s.strip.blank?
      raise "#{item.name} has no location on it, so there's nothing to measure - " \
            "ask where it is, or say plainly that it doesn't have a place yet"
    end

    { summary: "Check the drive for #{item.name}", resolved: { agenda_item_id: item.display_id, name: item.name } }
  },
  label:       ->(payload, _ctx) { { title: "🚗 #{payload[:name]}", sub: "drive time" } },
  execute:     ->(payload, ctx) {
    item = AgendaItem.locate_for_user(payload[:agenda_item_id], ctx.user)

    next { name: payload[:name], gone: true } if item.nil?

    # Measured only when we haven't got it. The chain caches on a fingerprint,
    # so a row that already knows its drive costs no Google round-trip; one that
    # doesn't gets a real one. `refresh_for` rather than `force_refresh_for` —
    # forcing re-bills every call for an answer that hasn't changed.
    if item.travel_seconds.nil? && item.persisted?
      AgendaTravelChain.refresh_for(item)
      item.reload
    end

    zone  = ctx.user.timezone
    drive = item.travel_seconds
    clock = ->(t) { t&.in_time_zone(zone)&.strftime("%-I:%M %p") }

    {
      name:       item.name,
      where:      item.location,
      drive_min:  drive && (drive / 60.0).ceil,
      leave_by:   clock.call(item.travel_hash["leave_at"].to_i.positive? ? Time.zone.at(item.travel_hash["leave_at"].to_i) : nil),
      home_by:    clock.call(item.home_at),
      # Already spaced and already rounded, so it can be handed straight to
      # `at` or `leave_at`. See Buddy::FollowUp.
      follow_on:  clock.call(Buddy::FollowUp.after(item.home_at)),
      unresolved: (true if drive.nil?),
    }.compact
  },
  receipt:     ->(result, _ctx) {
    next "#{result[:name]} isn't on the calendar any more" if result[:gone]

    if result[:unresolved]
      next "Couldn't place #{result[:where]}, so there's no drive time for #{result[:name]} ✓"
    end

    parts = ["#{result[:drive_min]}m to #{result[:where]}"]
    parts << "leave #{result[:leave_by]}" if result[:leave_by]
    parts << "home #{result[:home_by]}" if result[:home_by]
    "#{result[:name]} - #{parts.join(", ")} ✓"
  },
)
