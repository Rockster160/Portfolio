Buddy::Tools.register(
  name:        :edit_plan,
  summary:     "Change or cancel a plan already set up - the reminders, watches and stop rules one " \
               "request made - as one thing: push it all back an hour, change what it waits for or " \
               "runs, add a condition, cancel the lot.",
  description: <<~TXT,
    Change a plan that's already running, whole. One request often becomes
    several rows - a watch that runs things, a reminder later that night, the
    rule that stops it - and in `upcoming_reminders` / `active_watches` each
    of those carries the same `plan` id. This changes them together, so
    "push the garage stuff back an hour", "only do that on weekdays", "have it
    tell Chelsea instead" and "forget the whole thing" are each ONE call.

    `plan` is that id (`p4821`), or words from any of its parts, for the whole
    plan. A row's own id (`412`) aims at that one part alone - which is also
    how a reminder with no `plan` tag is changed here.

    Change only what they mentioned; everything else stays as it is.

      shift       move every timed part by this much: "+1h", "-30m", "+1d"
      at          the new time, when the plan has exactly one timed part
      only_if     replace what has to hold before any part goes ahead - the
                  same JSON array schedule_reminder and remind_when take.
                  `[]` removes every condition.
      only_if_any with only_if: any one of them instead of all
      trigger, target, listener, when_phrase, past_phrase
                  change what its watch waits for - remind_when's arguments
      steps       replace what it runs (JSON array of {tool_name, payload})
      add_steps   run these as well, after what it already runs
      text        new wording, when only one part says anything
      notify      who it's for: a household member's first name, or "me"
      expires     last day its watch stays armed ("today", "friday")
      cancel      true removes every part

    Something it can't change raises before anything moves, and says which
    part was the problem - pass the row id as `plan` to aim at it alone.
  TXT
  args:        {
    plan:        { type: :string,  required: true,  description: "The `plan` id from context or words from it for the whole plan; one row's id for just that part" },
    shift:       { type: :string,  required: false, description: "Move every timed part by this much: \"+1h\", \"-30m\", \"+1d\"" },
    at:          { type: :string,  required: false, description: "New time (ISO-8601 with offset), when there's one timed part" },
    only_if:     { type: :string,  required: false, description: "JSON array of conditions replacing the current ones; [] clears them" },
    only_if_any: { type: :boolean, required: false, description: "With only_if: go ahead when ANY holds" },
    trigger:     { type: :enum,    required: false, values: Buddy::WatchCondition::TRIGGERS, description: "New condition for its watch, as remind_when takes it" },
    target:      { type: :string,  required: false, description: "With trigger: the place / chore / event / calendar" },
    listener:    { type: :string,  required: false, description: "With trigger=custom: the Jil listener" },
    when_phrase: { type: :string,  required: false, description: "With trigger=custom: what the listener means" },
    past_phrase: { type: :string,  required: false, description: "With trigger=custom: the same, as having happened" },
    steps:       { type: :string,  required: false, description: "JSON array of {tool_name, payload} replacing what it runs" },
    add_steps:   { type: :string,  required: false, description: "JSON array of {tool_name, payload} to run after what it already runs" },
    text:        { type: :string,  required: false, description: "New wording, for a plan with one part that speaks" },
    notify:      { type: :string,  required: false, description: "Who it's for now: a household member's first name, or \"me\"" },
    expires:     { type: :string,  required: false, description: "Last day its watch stays armed" },
    cancel:      { type: :boolean, required: false, description: "Remove every part of the plan" },
  },
  # Plans come and go; a saved copy would edit whichever one exists next week.
  routinable:  false,
  confirm:     ->(payload, ctx) { Buddy::PlanEdit.new(ctx, payload).resolve },
  label:       ->(payload, _ctx) {
    { title: payload[:title].to_s.presence || "Change plan", sub: Array(payload[:lines]).join("\n").presence }
  },
  # Level 2: it lands now, and unticking the row puts every part back.
  level:       2,
  execute:     ->(payload, ctx) { Buddy::PlanEdit.apply!(ctx, payload) },
  receipt:     ->(result, _ctx) {
    lines = Array(result[:lines])
    "#{result[:title]}#{":" if lines.any?} #{lines.join("; ")} ✓".squish
  },
)
