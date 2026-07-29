Buddy::Tools.register(
  name:        :delete_event,
  description: <<~TXT,
    Delete a previously-logged event (an ActionEvent) - including ones logged
    outside of you. Use when the person says they logged something by mistake or
    wants it gone. Best to pass a specific `id` (from a `search_events` result);
    otherwise `event` is a fuzzy name and `when` narrows it.
  TXT
  args:        {
    id:    { type: :integer, required: false, description: "Exact ActionEvent id (e.g. from search_events)" },
    event: { type: :string,  required: false, description: "Fuzzy event name (if no id)" },
    when:  { type: :string,  required: false, default: "last", description: "One of: today, yesterday, this morning, last" },
  },
  confirm:     ->(payload, ctx) {
    event = payload[:id].present? ? ctx.user.action_events.find_by(id: payload[:id]) : ctx.resolve_event(payload[:event], hint: payload[:when] || "last")
    raise "no event matching #{(payload[:id] || payload[:event]).inspect}" if event.nil?

    { summary: "Delete #{event.name}?", resolved: { action_event_id: event.id, event_name: event.name } }
  },
  # Level 2: removes it right away as a PRE-CHECKED row; unchecking restores it
  # (the revert descriptor recreates the ActionEvent). So a wrong guess is one
  # tap to undo.
  level:       2,
  label:       ->(payload, ctx) {
    event = ActionEvent.find_by(id: payload[:action_event_id])
    # Destructive: surface WHEN it was logged (full date + time) and a note
    # snippet so the person can confirm it's the right record before it's gone.
    subs = []
    if event
      subs << event.timestamp.in_time_zone(ctx.user.timezone).strftime("%a %b %-d, %-I:%M %p")
      subs << "“#{event.notes.to_s.truncate(40)}”" if event.notes.present?
    end
    { title: "Delete #{event&.name || payload[:event]}", sub: subs.join(" · ").presence }
  },
  execute:     ->(payload, ctx) {
    event = ActionEvent.find(payload[:action_event_id])
    name  = event.name
    # Snapshot enough to rebuild it, so `undo` can bring it back (ActionEvent
    # hard-deletes — no soft-delete to unarchive).
    attrs = { user_id: event.user_id, name: event.name, notes: event.notes, timestamp: event.timestamp, data: event.data }
    event.destroy!
    # Same side effects as an in-app delete: :event trigger + broadcast.
    ActionEventNotifier.notify(ctx.user, event, :removed, auth: :buddy, auth_id: ctx.user.id)
    {
      deleted_name: name,
      revert:       { op: "recreated", model: "ActionEvent", attrs: attrs, summary: "brought back #{name}" },
    }
  },
  receipt:     ->(result, _ctx) { "Deleted #{result[:deleted_name]} ✓" },
)
