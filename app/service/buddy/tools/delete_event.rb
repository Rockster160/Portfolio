Buddy::Tools.register(
  name:        :delete_event,
  description: <<~TXT,
    Delete a previously-logged event. Use when the user says they logged
    something by mistake or wants it gone.
  TXT
  args: {
    event: { type: :string, required: true,  description: "Fuzzy event name" },
    when:  { type: :string, required: false, default: "last", description: "One of: today, yesterday, this morning, last" },
  },
  confirm: ->(payload, ctx) {
    event = ctx.resolve_event(payload[:event], hint: payload[:when] || "last")
    raise "no event matching #{payload[:event].inspect}" if event.nil?

    { summary: "Delete #{event.name}?", resolved: { action_event_id: event.id, event_name: event.name } }
  },
  label: ->(payload, _ctx) {
    event = ActionEvent.find_by(id: payload[:action_event_id])
    "Delete: #{event&.name || payload[:event]} (#{event&.timestamp&.strftime('%-I:%M %p')})"
  },
  execute: ->(payload, _ctx) {
    event = ActionEvent.find(payload[:action_event_id])
    name = event.name
    event.destroy!
    { deleted_name: name }
  },
  receipt: ->(result, _ctx) { "Deleted #{result[:deleted_name]} ✓" },
)
