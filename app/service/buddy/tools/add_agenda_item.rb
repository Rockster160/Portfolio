Buddy::Tools.register(
  name:        :add_agenda_item,
  description: <<~TXT,
    Add a new item to the user's calendar/agenda. Use for appointments,
    events, or tasks tied to a specific time. `at` is an ISO datetime.
    `duration` is in minutes. `kind` is one of: event, task, trigger.
    For v1, only writes to the user's primary local agenda (Google-synced
    calendars require the app's normal add flow).
  TXT
  args: {
    title:    { type: :string,       required: true,  description: "What is it" },
    at:       { type: :iso_time,     required: true,  description: "ISO datetime with timezone offset" },
    duration: { type: :duration_min, required: false, default: 30, description: "Minutes" },
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
    "#{payload[:title]} · #{time} (#{payload[:duration]}m)"
  },
  execute: ->(payload, ctx) {
    agenda = Agenda.find(payload[:agenda_id])
    duration = payload[:duration].to_i
    start_at = payload[:at]
    end_at = start_at + duration.minutes
    item = agenda.agenda_items.create!(
      title:   payload[:title],
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
    "Added #{item&.title || 'that'} to your calendar ✓"
  },
)
