Buddy::Tools.register(
  name:        :save_routine,
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

        [{"tool_name":"call_jil_function","payload":{"name":"Printer - Power On"}},
         {"tool_name":"set_timer","payload":{"duration":"1m","then_continue":true}},
         {"tool_name":"call_jil_function","payload":{"name":"Printer - Preheat"}}]

    A WAIT between two steps is `set_timer` with `then_continue: true`, same as
    in a live sequence - the routine pauses there and picks itself back up.

    Saving over an existing name REPLACES its steps, which is how they edit one.
    Steps are checked before anything is stored, so a bad tool name or a missing
    argument comes straight back to you and nothing half-broken gets saved.

    `name` is what they'll say to run it - keep it close to their own words.
  TXT
  args:        {
    name:         { type: :string,  required: true,  description: "What they'll call it, in their words" },
    description:  { type: :string,  required: false, description: "One short line on what it does" },
    steps:        { type: :string,  required: false, description: "JSON array of {tool_name, payload}, in order" },
    capture_last: { type: :integer, required: false, description: "Save the last N things you just did, instead of `steps`" },
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
        parsed = JSON.parse(payload[:steps].to_s) rescue nil
        raise "steps needs to be a JSON array of {tool_name, payload}" unless parsed.is_a?(Array)

        parsed
      end
    )

    steps = Buddy::Routines.sanitize(rows)
    { summary: "Save **#{title}**?", resolved: { routine_name: title, steps: steps } }
  },
  label:       ->(payload, _ctx) {
    lines = Array(payload[:steps]).map { |s| BuddyRoutine.step_phrase(s) }
    { title: payload[:routine_name].to_s, sub: lines.join("\n").presence }
  },
  execute:     ->(payload, ctx) {
    name    = payload[:routine_name].to_s
    steps   = Array(payload[:steps])
    routine = ctx.user.buddy_routines.where("LOWER(name) = ?", name.downcase).first

    if routine
      routine.update!(name: name, steps: steps, description: payload[:description].presence || routine.description)
    else
      routine = ctx.user.buddy_routines.create!(name: name, steps: steps, description: payload[:description])
    end

    { routine_id: routine.id, routine_name: routine.name, step_count: steps.length, summary: routine.summary }
  },
  receipt:     ->(result, _ctx) {
    count = result[:step_count].to_i
    "Saved **#{result[:routine_name]}** - #{count} #{"step".pluralize(count)} ✓"
  },
)
