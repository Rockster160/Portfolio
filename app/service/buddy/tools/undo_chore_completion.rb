Buddy::Tools.register(
  name:        :undo_chore_completion,
  description: <<~TXT,
    Undo a chore completion - remove a record that a chore was done. Use
    when the user says they marked something by mistake, or wants to
    reverse a completion.
  TXT
  args:        {
    chore: { type: :string, required: true,  description: "Fuzzy chore name" },
    when:  { type: :string, required: false, default: "last", description: "One of: today, yesterday, last" },
  },
  confirm:     ->(payload, ctx) {
    completion = ctx.resolve_chore_completion(payload[:chore], hint: (payload[:when] || "last").to_sym)
    raise "no matching completion for #{payload[:chore].inspect}" if completion.nil?

    { summary: "Undo the #{completion.chore.name} completion?", resolved: { completion_id: completion.id, chore_id: completion.chore_id } }
  },
  label:       ->(payload, ctx) {
    completion = ChoreCompletion.find_by(id: payload[:completion_id])
    return "Undo #{payload[:chore]}" if completion.nil?

    # Destructive: show the full date + time it was marked so the person knows
    # exactly which completion is being reversed.
    when_str = completion.completed_at.in_time_zone(ctx.user.timezone).strftime("%a %b %-d, %-I:%M %p")
    { title: "Undo #{completion.chore.name}", sub: when_str }
  },
  execute:     ->(payload, ctx) {
    completion = ChoreCompletion.find(payload[:completion_id])
    # Shared undo path: destroy + rebuild streak + broadcast to the Chores app.
    ChoreCompletionUndoer.call(ctx.user, completion)
    { chore_id: payload[:chore_id] }
  },
  receipt:     ->(result, _ctx) {
    "Undid completion for #{Chore.find_by(id: result[:chore_id])&.name} ✓"
  },
)
