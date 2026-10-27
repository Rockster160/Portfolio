Buddy::Tools.register(
  name:        :log_event,
  summary:     "Log something that happened - a drink, meal, workout, feeling, check-in. A " \
               "household chore is complete_chore.",
  always:      true,
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

    A state they've come into has already happened, and it's logged the
    moment they say so: "I'm sick", "I think I'm coming down with
    something", "I need you to keep track of my symptoms" all log "Sick".
    Automations listen for these, so sympathy without the log means nothing
    starts tracking. Say sorry AND log it.

    `at` is for when it happened earlier than now - "I got sick yesterday
    morning", "had a coffee at 8". Leave it out for something happening now.
  TXT
  feature:     :events,
  args:        {
    name:  { type: :string, required: true,  description: "Short event label (e.g. 'Coffee', 'Push-ups')" },
    notes: { type: :string, required: false, description: "Optional free-form notes" },
    at:    { type: :iso_time, required: false, description: "When it happened (ISO), if earlier than now" },
  },
  # `at` is a Time straight from the model and an ISO string once the proposal
  # has been stored and run from there, so both read it through resolve_time.
  confirm:     ->(payload, ctx) {
    at = ctx.resolve_time(payload[:at]) if payload[:at].present?
    raise "that hasn't happened yet - a log is for something already done" if at&.future?

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
    at = ctx.resolve_time(payload[:at]) if payload[:at].present?
    event = ActionEvent.create!(
      user:      ctx.user,
      name:      payload[:name],
      notes:     payload[:notes],
      timestamp: at || Time.current,
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
