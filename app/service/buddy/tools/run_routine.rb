Buddy::Tools.register(
  name:        :run_routine,
  description: <<~TXT,
    Run one of the person's saved routines - a sequence they named once so they
    never have to spell it out again. "Prep my printer" is the shape: power the
    printer on, wait a minute, then preheat.

    The `routines` section of get_context lists what they have, each with the
    steps it runs. Match on what they asked for, and use the routine's `name`.

    Reach for this whenever what they said IS one of their routines, even
    loosely worded - "prep the printer", "do the printer thing", "wind down".
    Running the routine is better than doing the steps yourself: it's the exact
    sequence they saved, in order, with any waits intact.

    If nothing on the list matches, don't stretch a near-miss - just do the
    thing they asked for with the ordinary tools, and offer to save it as a
    routine with save_routine if it sounds like something they'll want again.
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
