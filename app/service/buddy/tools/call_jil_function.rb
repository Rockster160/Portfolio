Buddy::Tools.register(
  name:             :call_jil_function,
  description:      <<~TXT,
    Invoke a Jil FUNCTION task with typed args. Use when the person
    asks for something covered by a task in the `jil_functions`
    section of the live context file - anything from turning on
    lights with a color, starting the car with a destination and
    temp, adjusting a printer setting, etc.

    **The function runs before you write your reply, and whatever
    it returns comes straight back to you.** So don't announce what
    you're about to do and don't predict how it went - wait for the
    answer and say what actually came back. Many of these report
    real outcomes, including "that was already the case, so I did
    nothing", and saying otherwise describes something that never
    happened.

    These also ANSWER QUESTIONS, not just perform commands. A
    function that reads a sensor or device ("is the doggy door
    shut?", "did we leave the laundry gate open?", "what's the
    kennel sensor say?") is the right tool for that question. Set
    `expect_result: true` on those - it marks the call as a lookup,
    so no "✓ Called X" receipt is filed for it. Never guess a
    state, and never tell them you can't check something that has a
    function for it.

    **This happens the moment you call it, so it is the wrong tool the second
    they say WHEN.** "Play the nap sound at 11" is one thing to do at 11, not a
    thing to do now that mentions 11 — and it went off sixteen minutes early
    next to a sleeping dog (prod 3562). A time in the request is an instruction
    about when to act; it is never part of what to do.

    `schedule_function` is this same call with a time on it — same `name`, same
    arguments, plus `at` or `repeat`. Reach for that one. A call made here with
    a time in the request is refused rather than run, so saying it's set up when
    nothing was scheduled is a lie about a physical thing.

    Two hard limits:

    - **Only ever call a function that CHECKS or REPORTS to answer
      a question.** One that opens, closes, sets, turns, or starts
      something CHANGES the world, and reaching for it to satisfy
      your curiosity can physically move a blind or unlock a door.
      If the closest match is a command, it is not an answer - say
      you can't check that one.
    - **Never invent a name.** Call something that is literally on
      the `jil_functions` list. If nothing there reads the thing
      they asked about, say you don't have that wired - guessing a
      plausible-sounding name just fails silently.

    Read the file first: each function entry has `{ id, name,
    signature, description }`. The signature is raw Jil (e.g.
    `function("Temp" TAB Numeric BR "Dest" TAB String)::Boolean`)
    and shows the arg names + types. The description says what the
    function actually does - use it to decide WHICH function fits
    the request, since names alone are terse and mechanical.
    Match on purpose, not on name similarity.

    The list already contains only functions the person allowed you
    to call, and may include ones shared with them by someone else
    (those run under the owner's account, with the owner's devices
    and credentials).

    Pass args in the `args` object, one key per signature arg, using
    LOWERCASE_SNAKE_CASE of the arg name. Order them IN SIGNATURE
    ORDER - some tasks read their args by position, so key order
    matters. Example:

      Signature: function("Temp" TAB Numeric BR "Dest" TAB String)
      Call: name="Tesla Start", args={"temp": 72, "dest": "Home"}

    If required args are missing or ambiguous ("start the car" with
    no temp), ask the person a short follow-up. Don't guess numeric
    values. If nothing on the function list plausibly matches, tell
    them you don't have that wired.
  TXT
  feature:          :jil,
  args:             {
    name:          { type: :string, required: true, description: "Fuzzy function-task name to call" },
    # Declared purely so validate_payload keeps it OUT of the passthrough args -
    # it's an instruction to us, never a parameter for the Jil function.
    expect_result: {
      type:        :boolean,
      required:    false,
      description: "True when this call is a LOOKUP - the person asked a question and the " \
                   "function only reads. False/null for commands",
    },
    # All other k=v marker args pass through as function params. Only the two
    # above are declared; passthrough_args keeps the rest through validate_payload.
  },
  passthrough_args: true,
  # Level 1: car starts / navigation / house + light commands are highest-
  # confidence and fire immediately (the person asked for it to happen, not to
  # be asked again).
  level:            1,
  # Acts AND reports, in that order, inside the turn.
  #
  # Every other level-1 tool runs AFTER the reply is written, which is fine when
  # the outcome is a foregone conclusion. These aren't: a function can come back
  # "already closed, nothing sent", or refuse, or report a state nobody could
  # predict. Prod 2789 is the cost of guessing - Byte said "Garage's closing"
  # while the call was still in flight, then had to fire a SECOND function to
  # find out what happened, and reported that read (taken 33ms before its own
  # toggle) as the outcome.
  #
  # Running here means one call answers the request: the return value is in
  # front of the model before it writes a word, and the relay turn is gone.
  answers:          true,
  acts:             true,
  confirm:          ->(payload, ctx) {
    q = payload[:name].to_s.downcase.strip
    scope = ctx.user.accessible_tasks.buddy_visible.functions

    match = scope.detect { |t| t.name.downcase == q } ||
            scope.detect { |t| t.name.downcase.start_with?(q) } ||
            scope.detect { |t| t.name.downcase.include?(q) }

    raise "no Jil function matches #{payload[:name].inspect}" if match.nil?

    # HARD CHECK on reading with a writer. Told that functions answer status
    # questions, the model will reach for the nearest plausible one - it picked
    # `HASS Blinds` with action="position" for "are the blinds open?", which
    # doesn't report anything, it MOVES them. Prompt wording didn't hold, and the
    # failure is physical (a blind opens, a door unlocks), so it's enforced here:
    # a function may only answer a question if it describes itself as reporting.
    # Raising drops the proposal, which surfaces as the honest fallback reply
    # rather than a silent side effect.
    if ActiveModel::Type::Boolean.new.cast(payload[:expect_result])
      reads = /\b(?:check|checks|report|reports|reporting|state|status|read|reads|sensor|whether)\b/i
      unless reads.match?("#{match.name} #{match.description}")
        raise "#{match.name} changes something rather than reporting - can't answer a question with it"
      end
    end

    # Everything handed to us EXCEPT the two declared args is treated as a
    # function argument. String-key + string values - the Jil executor coerces
    # per the signature. `expect_result` is ours, not the function's; leaving it
    # in would pass a stray param to every task Buddy calls.
    fn_args = payload.except(:name, :expect_result).transform_keys(&:to_s)

    summary = if fn_args.empty?
      "Call **#{match.name}**? (no args)"
    else
      pretty = fn_args.map { |k, v| "#{k}=#{v.inspect}" }.join(" ")
      "Call **#{match.name}** with `#{pretty}`?"
    end
    { summary: summary, resolved: { task_id: match.id, task_name: match.name, fn_args: fn_args } }
  },
  label:            ->(payload, _ctx) {
    title = (payload[:task_name] || payload[:name]).to_s
    args = payload[:fn_args] || {}
    sub = args.map { |k, v| "#{k}: #{v}" }.join("\n").presence
    { title: title, sub: sub }
  },
  execute:          ->(payload, ctx) {
    task = Task.find(payload[:task_id])
    fn_args = (payload[:fn_args] || {}).transform_keys(&:to_s)

    # Named args PLUS an ordered `params` array, mirroring what the Run-args
    # modal posts (run_args_modal.js `collectValues`). A function task reads
    # its args either way - `Keyword.NamedArg("x")` off the top-level key,
    # bare `Keyword.Item()` off `params` by position - and the listener alone
    # doesn't say which. Sending both means Buddy can call either style
    # without us parsing the Jil signature grammar server-side.
    input = fn_args.empty? ? {} : fn_args.merge("params" => fn_args.values)

    # auth_id is the ACTING user, which differs from the execution's user
    # whenever the task was shared: it runs as its owner, but Chelsea may be
    # the one who asked. Execution#auth_type/:buddy + auth_type_id is the
    # audit trail for that.
    execution = task.execute(
      input,
      auth:          :buddy,
      auth_id:       ctx.user.id,
      trigger_scope: "buddy",
    )

    # The timestamp is rewritten to local BEFORE the model sees it. Asking it to
    # convert one produced prod 2636: 18:58Z read back as "6:58 PM", the same
    # digits with the offset discarded, six hours out.
    raw    = execution.respond_to?(:result) ? execution.result.to_s.strip : ""
    answer = Buddy::RawOutput.localize(raw, ctx.user) if raw.present?
    lookup = ActiveModel::Type::Boolean.new.cast(payload[:expect_result])

    # An answering tool never reaches ProposalBuilder, so it files its own trace
    # (see Buddy::ActivityChip). A declared lookup skips it: Buddy is about to
    # speak the state itself, and a "Called X ✓" pill above that is noise.
    if ctx.conversation && !lookup
      Buddy::ActivityChip.post!(
        conversation: ctx.conversation,
        user:         ctx.user,
        tool_name:    :call_jil_function,
        body:         "Called **#{task.name}**",
        # What went out AND what came back. The prose above the chip is the
        # model's reading of the answer; this is the answer.
        detail:       [fn_args.map { |k, v| "#{k}: #{v}" }.join("\n").presence, answer.presence].compact.join("\n"),
        payload:      fn_args.merge("task_name" => task.name),
      )
    end

    {
      fired:     true,
      task_id:   task.id,
      task_name: task.name,
      answer:    answer,
      how:       (
        if answer.blank?
          "It ran and returned nothing to report, which is normal for a command. Say it's " \
            "done, briefly, and don't invent a result for it."
        else
          "`answer` is what the function itself reported and it is the outcome - say THAT, " \
            "not what you expected. Some of these come back saying nothing was done because " \
            "the thing was already that way; when one does, tell them that plainly instead of " \
            "describing an action. It is RAW output, so internal keys like `laundry_gate` " \
            "become \"the laundry gate\" and debug fields get dropped. Any time in it is " \
            "ALREADY their local time - read it as written and never shift it. If it reads " \
            "like an error or says something is unknown, say you couldn't get a reading rather " \
            "than inventing one. Don't mention the function or that you ran anything."
        end
      ),
    }.compact
  },
  # Deliberate opt-out, not a missing receipt. `execute` above files its own
  # ActivityChip with the function's actual answer on it, which is strictly
  # better than anything this could say — and when a routine runs this through
  # ProposalBuilder#run_auto, a receipt here would put a second, vaguer chip
  # directly under the first one.
  receipt:          ->(_result, _ctx) {},
)
