Buddy::Tools.register(
  name:        :edit_event,
  description: <<~TXT,
    Edit a recently-logged event - change name, notes, or timestamp. Pass a
    specific `id` (e.g. from search_events), or `event` as a fuzzy name with
    `when` to narrow it. Only include the fields that are changing.
  TXT
  args:        {
    id:    { type: :integer,  required: false, description: "Exact ActionEvent id (e.g. from search_events)" },
    event: { type: :string,   required: false, description: "Fuzzy name of the event to edit (if no id)" },
    when:  { type: :string,   required: false, default: "last", description: "One of: today, yesterday, this morning, last" },
    name:  { type: :string,   required: false, description: "New event name" },
    notes: { type: :string,   required: false, description: "New notes" },
    at:    { type: :iso_time, required: false, description: "New timestamp (ISO)" },
  },
  confirm:     ->(payload, ctx) {
    event = payload[:id].present? ? ctx.user.action_events.find_by(id: payload[:id]) : ctx.resolve_event(payload[:event], hint: payload[:when] || "last")
    raise "no event matching #{(payload[:id] || payload[:event]).inspect}" if event.nil?

    { summary: "Edit #{event.name}?", resolved: { action_event_id: event.id } }
  },
  label:       ->(payload, _ctx) {
    event = ActionEvent.find_by(id: payload[:action_event_id])
    base = event&.name || payload[:event].to_s
    diffs = []
    diffs << "name → #{payload[:name]}" if payload[:name].present?
    diffs << "notes → #{payload[:notes].to_s.first(30)}" if payload[:notes].present?
    diffs << "time → #{payload[:at].strftime("%-I:%M %p")}" if payload[:at].respond_to?(:strftime)
    { title: base, sub: diffs.join("\n").presence }
  },
  execute:     ->(payload, ctx) {
    event = ActionEvent.find(payload[:action_event_id])
    attrs = {}
    attrs[:name]      = payload[:name]  if payload[:name].present?
    attrs[:notes]     = payload[:notes] if payload[:notes].present?
    attrs[:timestamp] = payload[:at]    if payload[:at].respond_to?(:strftime)
    before = attrs.keys.index_with { |k| event.public_send(k) }  # old values, for undo
    if attrs.any? && event.update!(attrs)
      ActionEventNotifier.notify(ctx.user, event, :changed, auth: :buddy, auth_id: ctx.user.id)
    end
    {
      action_event_id: event.id,
      revert:          { op: "updated", model: "ActionEvent", id: event.id, before: before, summary: "reverted the #{event.name} edit" },
    }
  },
  receipt:     ->(result, _ctx) {
    event = ActionEvent.find_by(id: result[:action_event_id])
    "Updated #{event&.name || "event"} ✓"
  },
)
