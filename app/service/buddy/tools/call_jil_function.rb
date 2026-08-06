Buddy::Tools.register(
  name:             :call_jil_function,
  description:      <<~TXT,
    Invoke a Jil FUNCTION task with typed args. Use when the person
    asks for something covered by a task in the `jil_functions`
    section of the live context file - anything from turning on
    lights with a color, starting the car with a destination and
    temp, adjusting a printer setting, etc.

    These also ANSWER QUESTIONS, not just perform commands. A
    function that reads a sensor or device ("is the doggy door
    shut?", "did we leave the laundry gate open?", "what's the
    kennel sensor say?") is the right tool for that question. Set
    `expect_result: true` on those: the function runs, and what it
    returns comes BACK to you so you can relay the real state in
    your next reply. So in THIS reply give only a short lead-in
    ("let me check") - never guess the state, and never tell them
    you can't check something that has a function for it.

    Two hard limits on answering a question this way:

    - **Only ever `expect_result` on a function whose description
      says it CHECKS or REPORTS.** A function that opens, closes,
      sets, turns, or starts something CHANGES the world, and
      calling one to satisfy your curiosity can physically move a
      blind or unlock a door. If the closest match is a command,
      it is not an answer - say you can't check that one.
    - **Never invent a name.** Call something that is literally on
      the `jil_functions` list. If nothing there reads the thing
      they asked about, say you don't have that wired - guessing a
      plausible-sounding name just fails silently.

    Leave `expect_result` false (or null) for commands. Turning a
    light on doesn't need its return value relayed, and a pointless
    second message about it is worse than silence.

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
      description: "True when the person asked a QUESTION and you need what the function " \
                   "returns in order to answer. False/null for commands",
    },
    # All other k=v marker args pass through as function params. Only the two
    # above are declared; passthrough_args keeps the rest through validate_payload.
  },
  passthrough_args: true,
  # Level 1: car starts / navigation / house + light commands are highest-
  # confidence and fire immediately (the person asked for it to happen, not to
  # be asked again). A receipt confirms it went — so speaking it as done is
  # accurate here, unlike a confirm-gated proposal.
  level:            1,
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

    # A function's return value (`Jil::Executor#result`) is the ONLY way a
    # status question gets answered - "is the gate open" is unanswerable from
    # context, and the chip alone would just say the call went out. Relay it
    # through a fresh Buddy turn (same shape as check_weather) so the state
    # arrives in Buddy's own words instead of as a raw string.
    answer  = execution.respond_to?(:result) ? execution.result : nil
    wanted  = ActiveModel::Type::Boolean.new.cast(payload[:expect_result])
    relayed = wanted && answer.to_s.strip.present? && !ctx.conversation.nil?

    if relayed
      Buddy::CompanionDelivery.deliver_prompt(
        user:         ctx.user,
        conversation: ctx.conversation,
        # Grounded in what these actually return. A real run of task 435 came
        # back "laundry_gate is closed (raw state: off, last changed:
        # 2026-07-30T02:14:14.188937+00:00)" - an internal key, a debug field,
        # and a UTC timestamp, none of which Buddy is allowed to say out loud.
        #
        # The timestamp is rewritten to local BEFORE the model sees it. Asking
        # it to convert one produced prod 2636: 18:58Z read back as "6:58 PM",
        # the same digits with the offset discarded, six hours out.
        seed:         "You just ran **#{task.name}** to check on something for #{ctx.user.first_name} " \
                      "and it came back:\n\n#{Buddy::RawOutput.localize(answer.to_s.strip, ctx.user)}\n\n" \
                      "That is RAW output - translate it into how they'd actually say it. Internal keys " \
                      "like `laundry_gate` become \"the laundry gate\" and debug fields get dropped. Any " \
                      "time in there is ALREADY their local time - read it as written, and never shift " \
                      "it. Lead with the state itself, warm and brief. If " \
                      "it reads like an error or says something is unknown, tell them plainly you couldn't " \
                      "get a reading rather than inventing a state. Don't mention the function or that you " \
                      "ran anything, and don't check again.",
        metadata:     { "kind" => "buddy_trigger", "hidden" => true, "source" => "jil_function_result" },
      )
    end

    { fired: true, task_id: task.id, task_name: task.name, answer: answer, relayed: relayed }
  },
  # Nil suppresses the chip entirely (see ProposalBuilder#run_auto): when Buddy
  # is about to speak the answer itself, a "Called X ✓" pill above it is noise.
  receipt:          ->(result, ctx) {
    next nil if result.is_a?(Hash) && result[:relayed]

    # Name comes off the execute result first. `ctx.proposal` is nil on the
    # level-1 path (ProposalBuilder#run_auto builds a context without one), so
    # reaching into it was raising NoMethodError, getting swallowed by `safely`,
    # and silently suppressing this chip on every call.
    name = (result.is_a?(Hash) ? result[:task_name].presence : nil) ||
           ctx.proposal&.dig("payload", "task_name") ||
           "function"
    "Called **#{name}** ✓"
  },
)
