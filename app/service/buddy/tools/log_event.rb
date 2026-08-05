Buddy::Tools.register(
  name:        :log_event,
  description: <<~TXT,
    Log an ActionEvent - meals, drinks, workouts, water intake, feelings,
    check-ins, whatever the user wants tracked. `name` is what happened
    (short label). `notes` are optional. Use `count=N` when the same
    thing repeats (e.g. 5 glasses of water, 20 push-ups).

    ONLY for something that ALREADY HAPPENED. A log is a record of the past,
    and a plan is not one: "I'm about to have lunch", "I'm planning on sitting
    down to eat", "I'll grab a coffee after this" are all things that have not
    occurred, and writing them down as though they had puts a fact in their
    history that isn't true. React warmly and log nothing; if they want it
    held, that's the agenda. The moment they say they DID it, log it then.
  TXT
  feature:     :events,
  args:        {
    name:  { type: :string, required: true,  description: "Short event label (e.g. 'Coffee', 'Push-ups')" },
    notes: { type: :string, required: false, description: "Optional free-form notes" },
  },
  confirm:     ->(payload, _ctx) {
    { summary: "Log #{payload[:name]}?", resolved: {} }
  },
  label:       ->(payload, _ctx) {
    notes = payload[:notes].to_s
    { title: payload[:name].to_s, sub: (notes if notes.present? && notes.length < 60) }
  },
  merge_key:   ->(payload) { "log_event:#{payload[:name].to_s.downcase.strip}" },
  merge_label: ->(payload, count) { "#{count}× #{payload[:name]}" },
  # Level 2: logs immediately as a pre-checked row; unchecking deletes the log.
  level:       2,
  execute:     ->(payload, ctx) {
    event = ActionEvent.create!(
      user:      ctx.user,
      name:      payload[:name],
      notes:     payload[:notes],
      timestamp: Time.current,
      data:      { source: "buddy" },
    )
    # Same side effects as an in-app log: fire the :event trigger (so watches +
    # automations react) and broadcast to open views. ActionEvent has no model
    # callback for this on purpose (backfills skip it), so we call it here.
    ActionEventNotifier.notify(ctx.user, event, :added, auth: :buddy, auth_id: ctx.user.id)
    {
      action_event_id: event.id,
      revert:          { op: "created", model: "ActionEvent", id: event.id, summary: "removed the #{event.name} log" },
    }
  },
  receipt:     ->(result, _ctx) {
    event = ActionEvent.find_by(id: result[:action_event_id])
    "Logged #{event&.name || "event"} ✓"
  },
)
