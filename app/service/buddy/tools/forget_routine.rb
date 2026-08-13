Buddy::Tools.register(
  name:        :forget_routine,
  description: <<~TXT,
    Delete one of their saved routines. Use when they say to drop it, forget it,
    or that they don't use it anymore. `name` is fuzzy - match it against the
    `routines` section of get_context.

    To CHANGE a routine, don't delete it first: `edit_routine` patches one
    step's arguments, and save_routine over the same name replaces its steps.
  TXT
  args:        {
    name: { type: :string, required: true, description: "Routine name to delete" },
  },
  routinable:  false,
  confirm:     ->(payload, ctx) {
    routine = Buddy::Routines.find(ctx.user, payload[:name])
    raise "no routine called #{payload[:name].inspect}" if routine.nil?

    {
      summary:  "Delete **#{routine.name}**?",
      resolved: { routine_id: routine.id, routine_name: routine.name, steps: routine.summary },
    }
  },
  label:       ->(payload, _ctx) {
    { title: "Delete #{payload[:routine_name]}", sub: Array(payload[:steps]).join("\n").presence }
  },
  execute:     ->(payload, ctx) {
    routine = ctx.user.buddy_routines.find_by(id: payload[:routine_id])
    raise "that routine is already gone" if routine.nil?

    name = routine.name
    routine.destroy!
    { routine_name: name }
  },
  receipt:     ->(result, _ctx) { "Deleted **#{result[:routine_name]}** ✓" },
)
