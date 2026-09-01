Buddy::Tools.register(
  name:        :edit_routine,
  description: <<~TXT,
    Change ONE step of a routine they already saved, leaving every other step
    exactly as it is. "The lockdown script was supposed to be darkness, not
    total darkness" is this.

    ## Why this and not save_routine

    `save_routine` over the same name replaces the WHOLE sequence, which means
    writing out every step again. You can only see a routine's steps as short
    phrases in `routines` - "call jil function: HASS Scene" tells you the tool
    and the name and nothing about its other arguments - so re-saving from
    those phrases silently drops whatever they didn't mention. Use this when
    they're correcting a detail, and `save_routine` when they're describing the
    sequence over from scratch.

    ## Arguments

      name: the routine, fuzzy, matched against `routines` in get_context.
      step: WHICH step, counting from 1 down the `steps` list of that entry.
      set:  a JSON object of the arguments to change on that step, e.g.
            {"scene":"darkness"}. Only the keys you name are touched; the rest
            of that step's arguments stay as they were.

    The changed step is re-checked before anything is stored, exactly as a
    fresh save is - so a value that matches nothing of theirs comes straight
    back to you while they're still here to say which one they meant.

    To change WHICH steps there are, or their order, that's `save_routine` with
    the full sequence. To delete a routine outright, `forget_routine`.

    **A correction is a tool call.** They told you a saved routine is wrong;
    saying you fixed the wording without calling this leaves the routine armed
    with the value they just told you was wrong, and now they think it's
    handled. (This one really happened - prod routine 4, the lockdown scene.)

    **A ROUTINE THEY SAY IS BROKEN MAY ALREADY BE RIGHT.** If this comes back
    saying the step is already set that way, that is the answer: do not try
    again with the same values, and do not report a fix. The routine stores what
    they asked for, and the fault is downstream of it - the function it calls,
    or the device on the end. Say the routine already reads correctly and that
    the problem is elsewhere. Repeating the call is how one wrong blind became
    three rounds of "fixed" against a routine that never changed.
  TXT
  args:        {
    name: { type: :string,  required: true, description: "Routine name, fuzzy" },
    step: { type: :integer, required: true, description: "Which step to change, 1-based, in the order `routines` lists them" },
    set:  { type: :string,  required: true, description: "JSON object of arguments to change on that step, e.g. {\"scene\":\"darkness\"}" },
  },
  # Same level as save_routine: a correction they just asked for out loud, on a
  # record that is only ever read when they run it. Waiting on a tap would leave
  # the wrong value armed for exactly as long as it takes them to notice.
  level:       1,
  # Editing a routine from inside a routine is a knot with no use case behind
  # it, and the same reason save_routine and forget_routine are excluded.
  routinable:  false,
  confirm:     ->(payload, ctx) {
    routine = Buddy::Routines.find(ctx.user, payload[:name])
    raise "no routine called #{payload[:name].inspect}" if routine.nil?

    steps = Array(routine.steps).map(&:deep_dup)
    index = payload[:step].to_i
    unless index.between?(1, steps.length)
      raise "#{routine.name} has #{steps.length} step#{"s" if steps.length != 1}, so there's no step #{index}"
    end

    changes = (JSON.parse(payload[:set].to_s) rescue nil)
    raise "`set` needs to be a JSON object of the arguments to change" unless changes.is_a?(Hash)
    raise "`set` is empty - name at least one argument to change" if changes.empty?

    target = steps[index - 1]
    was    = BuddyRoutine.step_phrase(target)
    # Merged, not replaced. The step's other arguments are the ones nobody
    # mentioned, and they're also the ones that can't be read back off the
    # summary phrase - so replacing the payload wholesale is how "fix the
    # scene" quietly drops the position the blinds close to.
    target["payload"] = (target["payload"] || {}).merge(changes.transform_keys(&:to_s))

    # The same gate a fresh save goes through, over the whole sequence rather
    # than the one step: check_var_flow! is a property of the routine, not of
    # any step in it, and an edit can break it.
    checked = Buddy::Routines.sanitize(steps, ctx)

    # AN EDIT THAT CHANGES NOTHING IS NOT A FIX, and saying it was is worse
    # than saying nothing: they stop looking at the routine, which was never
    # the problem, and the thing that IS wrong keeps happening.
    #
    # Prod 1 Sep, Puppy Window mode. The routine read
    # `great_bottom_right / open / 20` from the moment it was made and was
    # right the whole time; the blind moved wrongly because task 429 inverted
    # the percentage on its way to the house. Told the routine was broken,
    # three separate turns rewrote it to the identical payload and reported it
    # fixed (5128, 5136, 5142), and the person re-ran it and hit the same wall
    # each time. The step PHRASE carries no arguments, so `was` and `now` were
    # the same string and even the chip couldn't show there was no difference.
    #
    # Compared against what is stored, so this catches a no-op however it
    # arises. It fails OPEN - if `sanitize` normalizes a stored step, the two
    # won't match and the write goes ahead as before, which is the safe
    # direction for a guard whose false positive would block a real correction.
    if checked.as_json == Array(routine.steps).as_json
      raise "step #{index} of #{routine.name} is already set that way, so there is nothing to change. " \
            "Tell them it already reads what they asked for rather than reporting a fix, and that whatever " \
            "is going wrong is happening somewhere other than this routine."
    end

    {
      summary:  "Change step #{index} of **#{routine.name}**?",
      resolved: {
        routine_id:   routine.id,
        routine_name: routine.name,
        step_index:   index,
        steps:        checked,
        was:          was,
        now:          BuddyRoutine.step_phrase(checked[index - 1]),
      },
    }
  },
  label:       ->(payload, _ctx) {
    { title: payload[:routine_name].to_s, sub: ["step #{payload[:step_index]}", payload[:was], "→ #{payload[:now]}"].compact_blank.join("\n") }
  },
  execute:     ->(payload, ctx) {
    routine = ctx.user.buddy_routines.find_by(id: payload[:routine_id])
    raise "that routine is gone" if routine.nil?

    routine.update!(steps: Array(payload[:steps]))
    { routine_name: routine.name, step_index: payload[:step_index], now: payload[:now] }
  },
  receipt:     ->(result, _ctx) { "**#{result[:routine_name]}** step #{result[:step_index]} → #{result[:now]} ✓" },
)
