Buddy::Tools.register(
  name:        :add_agenda_item,
  description: <<~TXT,
    Add a new item to the user's calendar/agenda. Use for appointments,
    events, or tasks tied to a specific time. `at` is an ISO datetime.
    `duration` is in minutes. `kind` is one of: event, task, trigger.
    Pull the PLACE into `location`, not the title: "coffee at Lucky Ones"
    → title "Coffee", location "Lucky Ones". "dentist" with no place →
    no location. For v1, only writes to the user's primary local agenda
    (Google-synced calendars require the app's normal add flow).
  TXT
  args: {
    title:    { type: :string,       required: true,  description: "What is it (the activity, WITHOUT the place)" },
    at:       { type: :iso_time,     required: true,  description: "ISO datetime with timezone offset" },
    duration: { type: :duration_min, required: false, default: 30, description: "Minutes" },
    location: { type: :string,       required: false, description: "Place/venue/address, if one was mentioned" },
    kind:     { type: :enum,         required: false, default: :event, values: %i[event task trigger] },
    all_day:  { type: :string,       required: false, description: "'true' for all-day" },
  },
  confirm: ->(payload, ctx) {
    agenda = Agenda.where(user_id: ctx.user.id).reject(&:managed_externally?).first
    raise "no local agenda available" if agenda.nil?

    { summary: "Add #{payload[:title]} to your calendar?", resolved: { agenda_id: agenda.id } }
  },
  label: ->(payload, ctx) {
    time = payload[:at].respond_to?(:strftime) ? payload[:at].in_time_zone(ctx.user.timezone).strftime("%a %b %-d, %-I:%M %p") : payload[:at].to_s
    bits = ["#{time} (#{payload[:duration]}m)"]
    bits << "@ #{payload[:location]}" if payload[:location].present?
    { title: payload[:title].to_s, sub: bits.join(" · ") }
  },
  execute: ->(payload, ctx) {
    agenda = Agenda.find(payload[:agenda_id])
    # `at` arrives here as an ISO STRING (the payload was JSON-serialized onto
    # the ByteAction between build and execute), so parse it back to a Time.
    start_at = ctx.resolve_time(payload[:at])
    raise "couldn't parse the start time" if start_at.nil?

    duration = payload[:duration].to_i
    duration = 30 if duration <= 0
    end_at   = start_at + duration.minutes

    item = agenda.agenda_items.create!(
      name:     payload[:title],
      location: payload[:location].presence,
      start_at: start_at,
      end_at:   end_at,
      all_day:  payload[:all_day].to_s == "true",
      kind:     payload[:kind] || :event,
      status:   :confirmed,
    )
    { agenda_item_id: item.id }
  },
  receipt: ->(result, _ctx) {
    item = AgendaItem.find_by(id: result[:agenda_item_id])
    "Added #{item&.name || 'that'} to your calendar ✓"
  },
)
