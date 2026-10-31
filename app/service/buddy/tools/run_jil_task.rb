# One way to run any Jil task Buddy may reach, by name.
#
# A FUNCTION is called: its arguments go in, and its return value comes back.
# A TRIGGER is announced: its scope is fired with data, and every task
# listening on it whose filter the data satisfies runs. That difference is the
# engine's, and the task's own listener already says which it is - so the
# model names the task and this works out the rest, rather than the model
# choosing between two tools and a right name sent to the wrong one matching
# nothing.
#
# The work is still done by `call_jil_function` and `trigger_jil_task`, which
# stay registered (internal) because routines, scheduled calls and watches
# store their names.
Buddy::Tools.register(
  name:             :run_jil_task,
  summary:          "Run one of their automations by name, right now - lights, the car, the printer, " \
                    "cameras, scenes, fans. A name below that says what they asked is the call: \"skip the " \
                    "next nap\" is Whisper Skip Nap, not a reminder to cancel.",
  roster:           ->(user) { Buddy::Tools.jil_function_names(user) + Buddy::Tools.jil_trigger_names(user) },
  description:      <<~TXT,
    Run a Jil automation by name. Everything in the `jil_functions` and
    `jil_triggers` sections of the live context is reached through this one
    tool - name it and this works out which kind it is.

    Each entry has a `description`. READ IT - names are terse and mechanical
    ("Great Fan", "ESP Button") while the description says what it actually
    does. Match on what the person wants, not on name similarity. `name` must
    be the entry's `name` verbatim, and never invent one: if nothing on either
    list plausibly matches, say you don't have that wired.

    **It runs before you write your reply, and whatever it says comes straight
    back to you.** Don't announce what you're about to do and don't predict how
    it went - wait for the answer and say what actually came back. Many report
    real outcomes, including "that was already the case, so I did nothing".

    The task does its own checking, so don't look first. Finding no timer,
    reminder or schedule for the thing they named is not an answer: a task
    keeps its own state, and running it is how you find out whether there was
    anything to do.

    ## What to pass

    A `jil_functions` entry has a `signature` (raw Jil, e.g.
    `function("Temp" TAB Numeric BR "Dest" TAB String)::Boolean`). Its
    arguments go in `args`, one key per signature arg, LOWERCASE_SNAKE_CASE of
    the arg name, IN SIGNATURE ORDER:

      signature: function("Temp" TAB Numeric BR "Dest" TAB String)
      call:      name="Tesla Start", args={"temp": 72, "dest": "Home"}

    A `function()` takes nothing - leave `args` empty. If a required value is
    missing or ambiguous ("start the car" with no temp), ask a short follow-up.
    Don't guess numbers.

    A `jil_triggers` entry has a `listener`. When it is a bare word
    (`fan-high`) send no `data`. When it has colons, everything after the scope
    is a FILTER and `data` has to satisfy it, or nothing runs:

      * `scope:word`       - a bare word is a VALUE the data must contain. Pair
                             it with its natural key, almost always `action`:
                             `event:add` -> data="action:add".
      * `scope:key::Value` - that key must equal Value: data="key:Value".

      listener: `hass-button:device_name::"Laundry Button"`
      call:     name="Laundry Button", data="device_name:Laundry Button"

    `data` is space-separated `key:value` pairs, every piece with a colon, or a
    JSON object when a value has spaces or colons in it:
    data='{"name":"Tech Stand-Up: Daily","action":"add"}'. If the listener
    filters on something you can't work out from what they said, ask.

    A wrong shape is refused before anything runs, and the refusal says what
    the task takes - fix the call and make it again.

    ## Questions as well as commands

    A task that reads a sensor or a device ("is the doggy door shut?", "what's
    the kennel sensor say?") is the right tool for that question. Set
    `expect_result: true` on those - it marks the call as a lookup, so no
    receipt is filed for it. Never guess a state, and never say you can't
    check something that has a task for it.

    **Only a task that CHECKS or REPORTS may answer a question.** One that
    opens, closes, sets, turns or starts something CHANGES the world, and
    reaching for it to satisfy curiosity can move a blind or unlock a door. If
    the closest match is a command, it isn't an answer - say you can't check
    that one. `expect_result: true` on one is refused.

    **When their words fit more than one task, say which one you ran.** "Turn
    the fan to low" with two fans is a choice you made for them - name it:
    "great room fan's on low".

    ## Not now

    This happens the moment you call it, so it is the wrong tool the second
    they say WHEN. "Play the nap sound at 11" is `schedule_function`, the same
    name and arguments plus a time. On a condition rather than a clock ("once I
    leave") it is `remind_when` with `run`. A raw SCOPE they hand you
    (`some:jil:listener`) rather than a task's name is `schedule_trigger`.

    The lists only contain tasks the person allowed you to run, and may include
    ones shared with them by someone else (those run under the owner's account).
  TXT
  feature:          :jil,
  args:             {
    name:          { type: :string, required: true, description: "Task name, verbatim from `jil_functions` or `jil_triggers`" },
    data:          {
      type:        :string,
      required:    false,
      description: "A trigger's data, built from its listener: key:value pairs or a JSON object. A function's " \
                   "arguments go in `args`",
    },
    expect_result: {
      type:        :boolean,
      required:    false,
      description: "True when this call is a LOOKUP - the person asked a question and the task only reads. " \
                   "False/null for commands",
    },
    # A function's own arguments arrive as `args` and pass through.
  },
  passthrough_args: true,
  level:            1,
  # Acts and reports inside the turn, for both kinds: a trigger's tasks can say
  # something back too, and the reply should be written from what they said.
  answers:          true,
  acts:             true,
  confirm:          ->(payload, ctx) {
    data = payload[:data].to_s.strip.presence
    fn_args = payload.except(:name, :data, :expect_result)
    prefer = (:function if fn_args.any?) || (:trigger if data)
    task = ctx.resolve_jil_task(payload[:name], prefer: prefer)
    raise "no Jil task matches #{payload[:name].inspect}" if task.nil?

    row = ctx.user.accessible_tasks.buddy_visible.find_by(name: task[:name])

    # `args` and `data` are both key:value pairs, so one sent in the other's
    # place is read as what it meant. Whether the KEYS fit is checked below.
    if task[:kind] == :function
      fn_args = ::Tokenizing::TriggerData.parse(data, as: ctx.user).to_h.symbolize_keys if data && fn_args.empty?

      slots = ::Jil::FunctionSignature.slots(row.function_args_str)
      named = slots.filter_map { |slot| slot[:key] }
      stray = fn_args.keys.map(&:to_s) - named
      if stray.any? && named.length == slots.length
        takes = named.any? ? "takes #{named.map { |key| "`#{key}`" }.join(", ")}" : "takes no arguments"
        raise "Nothing ran: #{task[:name]} #{takes} (#{row.listener}), so " \
              "#{stray.map { |key| "`#{key}`" }.join(", ")} would go nowhere."
      end

      called = Buddy::Tools[:call_jil_function][:confirm].call(
        { name: task[:name], expect_result: payload[:expect_result] }.merge(fn_args),
        ctx,
      )
      next { summary: called[:summary], resolved: called[:resolved].merge(kind: :function) }
    end

    data ||= fn_args.to_json if fn_args.any?
    if ActiveModel::Type::Boolean.new.cast(payload[:expect_result]) &&
       !Buddy::Tools::JIL_READS_RX.match?("#{row.name} #{row.description}")
      raise "#{row.name} changes something rather than reporting - can't answer a question with it"
    end

    fired = Buddy::Tools[:trigger_jil_task][:confirm].call({ name: task[:name], data: data }, ctx)
    resolved = fired[:resolved]
    parsed = data ? ::Tokenizing::TriggerData.parse(data, as: ctx.user) : {}
    unless ::Jil::ListenerMatch.call(row.listener, resolved[:scope], parsed)
      raise "Nothing ran: #{task[:name]} listens for `#{row.listener}`, and " \
            "#{data ? "data `#{data}` doesn't" : "no data doesn't"} satisfy it. Build `data` from that listener."
    end

    lookup = ActiveModel::Type::Boolean.new.cast(payload[:expect_result])
    { summary: fired[:summary], resolved: resolved.merge(kind: :trigger, expect_result: lookup) }
  },
  label:            ->(payload, ctx) {
    tool = payload[:kind].to_s == "trigger" ? :trigger_jil_task : :call_jil_function
    Buddy::Tools[tool][:label].call(payload, ctx)
  },
  execute:          ->(payload, ctx) {
    next Buddy::Tools[:call_jil_function][:execute].call(payload, ctx) unless payload[:kind].to_s == "trigger"

    result = Buddy::Tools[:trigger_jil_task][:execute].call(payload, ctx)
    answer = result[:answer].to_s.strip.presence

    # Answering in-turn means nothing files a receipt for it, so this does -
    # the same chip a function call posts. A lookup skips it: Buddy is about
    # to say the state itself.
    if ctx.conversation && !ActiveModel::Type::Boolean.new.cast(payload[:expect_result])
      Buddy::ActivityChip.post!(
        conversation: ctx.conversation,
        user:         ctx.user,
        tool_name:    :run_jil_task,
        body:         "Fired **#{payload[:task_name]}**",
        detail:       [payload[:data].presence, answer].compact.join("\n"),
        payload:      { "task_name" => payload[:task_name], "data" => payload[:data] }.compact,
      )
    end

    result.merge(
      task_name: payload[:task_name],
      how:       (
        if answer
          "`answer` is what the automation itself said and it is the outcome - say THAT, not what " \
            "you expected. Any time in it is already their local time."
        else
          "It fired. Triggers usually say nothing back, so say it's done, briefly, and don't " \
            "invent a result for it."
        end
      ),
    )
  },
  # Both kinds post their own chip from `execute`.
  receipt:          ->(_result, _ctx) {},
)
