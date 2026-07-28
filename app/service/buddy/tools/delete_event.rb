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
    { title: "Delete #{event&.name || payload[:event]}", sub: event&.timestamp&.strftime("%-I:%M %p") }
  },
  execute: ->(payload, _ctx) {
    event = ActionEvent.find(payload[:action_event_id])
    name  = event.name
    # Snapshot enough to rebuild it, so `undo` can bring it back (ActionEvent
    # hard-deletes — no soft-delete to unarchive).
    attrs = { user_id: event.user_id, name: event.name, notes: event.notes, timestamp: event.timestamp, data: event.data }
    event.destroy!
    {
      deleted_name: name,
      revert: { op: "recreated", model: "ActionEvent", attrs: attrs, summary: "brought back #{name}" },
    }
  },
  receipt: ->(result, _ctx) { "Deleted #{result[:deleted_name]} ✓" },
)
