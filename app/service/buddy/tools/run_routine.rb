Buddy::Tools.register(
  name:        :run_routine,
  description: <<~TXT,
    Run one of the person's saved routines - a sequence they named once so they
    never have to spell it out again.

    A POWER-USER SHORTCUT, not a way of understanding requests. Almost nothing
    they say is a routine. Reach for this only when what they said matches the
    name of something actually sitting in the `routines` section of get_context,
    and pass that routine's `name`. When it does match, running it beats doing
    the steps by hand - it's the exact sequence they saved, in order, with any
    waits intact.

    Everything else is an ordinary request and goes to the ordinary tools. A
    phrase naming a device or a chore - the printer, the lights, the fan, the
    car - lives in `jil_triggers` and `jil_functions`, and that is where you
    look. Do NOT treat an unfamiliar short phrase as probably-a-routine, do not
    fetch the routines list to check, and never answer a request by reporting
    that no routine is saved for it: they asked for a thing to happen, and your
    filing is not an answer. Do the thing. If it's clearly something they'll ask
    for again, offering to save it AFTERWARDS is fine.
  TXT
  args:        {
    name: { type: :string, required: true, description: "Routine name, from the routines list" },
  },
  # Never actually reached: Turn#build_proposals swaps this call for the steps
  # it names before ProposalBuilder ever sees it, and each of those carries its
  # own level. Declared as 1 so nothing treats the run itself as a checkbox.
  level:       1,
  routinable:  false,
  confirm:     ->(payload, ctx) {
    routine = Buddy::Routines.find(ctx.user, payload[:name])
    raise "no routine called #{payload[:name].inspect}" if routine.nil?
    raise "#{routine.name} has no steps to run" if routine.markers.empty?

    routine.touch_run!
    {
      summary:  "Run **#{routine.name}**? (#{routine.summary.join(", ")})",
      resolved: { routine_id: routine.id, routine_name: routine.name, steps: routine.summary },
    }
  },
  label:       ->(payload, _ctx) {
    { title: (payload[:routine_name] || payload[:name]).to_s, sub: Array(payload[:steps]).join("\n").presence }
  },
  execute:     ->(payload, _ctx) {
    # Expansion happens in Buddy::GPT::Turn#build_proposals. Getting here means
    # a call slipped past it, and running nothing while reporting success is
    # exactly the failure a routine exists to prevent - so say so loudly.
    raise "routine #{payload[:routine_name].inspect} reached execute unexpanded"
  },
  receipt:     ->(_result, _ctx) {},
)
