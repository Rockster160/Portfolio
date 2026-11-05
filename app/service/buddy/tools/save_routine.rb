Buddy::Tools.register(
  name:        :save_routine,
  summary:     "\"When I say X, do Y\": saves Y under X, so saying X runs it from now on - one call or a " \
               "sequence, and X can carry a number (\"sleep timer 30\" turns the TV off in 30).",
  description: <<~TXT,
    Save a named sequence of your own tool calls so one phrase runs all of it
    later. "When I say prep my printer, turn it on, wait a minute, then preheat
    it" is exactly this, and so is "save that as my wind-down".

    Two ways to fill it in, and you pick based on whether the steps already
    happened:

    - **They just happened.** Pass `capture_last` - the number of things you
      just did for them - and the steps are read back from what actually ran.
      This is the one for "save that", "make that a routine", "do that with one
      word next time". You cannot see your own completed calls, so do NOT try to
      write them out from memory; `capture_last` is how you get them.
    - **They described it.** Pass `steps` as a JSON array, in order, each
      `{"tool_name": "...", "payload": {...}}` using the same arguments you'd
      send to call that tool directly. Example:

        [{"tool_name":"run_jil_task","payload":{"name":<a task from jil_triggers>}},
         {"tool_name":"set_timer","payload":{"seconds":<the wait they said>,"then_continue":true}},
         {"tool_name":"run_jil_task","payload":{"name":<the next task>}}]

    A WAIT between two steps is `set_timer` with `then_continue: true`, same as
    in a live sequence - the routine pauses there and picks itself back up.

    ## Steps that need an answer first

    A routine can also stop and ASK, then use what it's told:

    - `ask_me` puts a question to the person and files their answer under `var`.
    - Any of `ask_partner` / `ask_partner_choice` / `ask_partner_multi` with
      `await_reply: true` does the same with a household member, and picks back
      up whenever they reply - typed or tapped, either way.

    A later step reaches either answer by putting `{{that_var_name}}` in one of
    its arguments. "Ask me what I want for dinner, ask Chelsea what she wants,
    then send both to the dinner planner" is:

      [{"tool_name":"ask_me","payload":{"question":"What do you want for dinner?","var":"mine"}},
       {"tool_name":"ask_partner","payload":{"to":<who>,"question":"What do you want for dinner?","await_reply":true,"var":"theirs"}},
       {"tool_name":"run_jil_task","payload":{"name":<the planner task>,"mine":"{{mine}}","theirs":"{{theirs}}"}}]

    Every `{{name}}` must be collected by an EARLIER step - a routine can't use
    an answer it hasn't asked for yet, and one that tries is rejected here. Only
    add an asking step when something after it genuinely needs the answer; a
    routine that stops to ask a question nothing uses is just slower.

    ## Steps that are handed a value each time

    "When I say sleep timer and a number, turn the TV off in that many minutes"
    is a routine that is GIVEN something every time it runs. Name it in
    `inputs` and use it in a step the same way, as `{{minutes}}`:
      inputs: "minutes"
      [{"tool_name":"set_timer","payload":{"minutes":"{{minutes}}","then_continue":true}},
       {"tool_name":"run_jil_task","payload":{"name":<the TV task>,<its off argument>}}]
    Saying "sleep timer 30" then runs it with 30. The name is the words they say
    around the value, without the value.

    Saving over an existing name REPLACES its steps, and that is how a routine
    gets FIXED. When they tell you a routine you just saved is wrong - "it's
    supposed to complete the chore three times", "there shouldn't be an event in
    there", "drop the wait" - they are describing the SAVED STEPS, not asking
    you to go do those things now. Call save_routine again with the corrected
    steps under the same name. Running the steps live instead performs actions
    they never asked for and leaves the routine every bit as wrong as it was.

    When only one ARGUMENT is wrong - the scene, the chore, the count - that's
    `edit_routine`, which patches that step and leaves the others alone. Reach
    for it rather than this one, because `routines` shows you each step as a
    short phrase and not its full arguments, so re-saving the sequence from
    what you can see drops everything that phrase didn't mention. Either way it
    takes a call: agreeing that a routine is wrong and writing nothing leaves
    it armed exactly as it was.

    Every step is CHECKED before anything is stored - the tool has to exist, the
    arguments have to be complete, and each one has to actually resolve against
    their data. A chore name that matches nothing comes straight back to you
    here, while they're still in the conversation to tell you which one they
    meant. Use their real names: look chores, lists and tasks up in get_context
    rather than writing down what they said verbatim, because a routine saved
    against a name that doesn't exist can only ever fail.

    `name` is what they'll say to run it - keep it close to their own words.
  TXT
  args:        {
    name:         { type: :string,  required: true,  description: "What they'll call it, in their words" },
    description:  { type: :string,  required: false, description: "One short line on what it does" },
    steps:        { type: :string,  required: false, description: "JSON array of {tool_name, payload}, in order" },
    capture_last: { type: :integer, required: false, description: "Save the last N things you just did, instead of `steps`" },
    inputs:       {
      type:        :string,
      required:    false,
      description: "Names of the values it's handed each time it runs, comma-separated (\"minutes\"), used " \
                   "in steps as {{minutes}}. Null when it takes none",
    },
  },
  level:       1,
  routinable:  false,
  merge_key:   ->(payload) { "save_routine:#{payload[:name].to_s.downcase.strip}" },
  supersedes:  true,
  confirm:     ->(payload, ctx) {
    title = payload[:name].to_s.strip
    raise "a routine needs a name" if title.empty?

    rows = (
      if payload[:capture_last].present?
        raise "I need to be in a conversation to save what just happened" if ctx.conversation.nil?

        captured = Buddy::Routines.capture(ctx.conversation, limit: payload[:capture_last])
        raise "I can't find anything I just ran to save" if captured.empty?

        captured
      else
        Buddy::Routines.parse_rows(payload[:steps])
      end
    )

    inputs = Buddy::Routines.input_names(payload[:inputs])
    steps  = Buddy::Routines.sanitize(rows, ctx, inputs: inputs)
    { summary: "Save **#{title}**?", resolved: { routine_name: title, steps: steps, input_names: inputs } }
  },
  label:       ->(payload, _ctx) {
    lines = Array(payload[:steps]).map { |s| BuddyRoutine.step_phrase(s) }
    { title: payload[:routine_name].to_s, sub: lines.join("\n").presence }
  },
  execute:     ->(payload, ctx) {
    name    = payload[:routine_name].to_s
    steps   = Array(payload[:steps])
    routine = ctx.user.buddy_routines.where("LOWER(name) = ?", name.downcase).first
    routine ||= ctx.user.buddy_routines.new

    # Inputs alongside the steps, so the steps are checked against them. Saving
    # replaces both, the same way it always replaced the steps.
    routine.update!(
      name:        name,
      steps:       steps,
      description: payload[:description].presence || routine.description,
      metadata:    routine.metadata.to_h.merge("inputs" => Array(payload[:input_names])),
    )

    { routine_id: routine.id, routine_name: routine.name, step_count: steps.length, summary: routine.summary }
  },
  # No step count. The chip already lists the steps underneath, so the number
  # was restating what's right there — and "1 step" is a strange thing to be
  # told about something you just described in one sentence.
  receipt:     ->(result, _ctx) { "Saved **#{result[:routine_name]}** ✓" },
)
