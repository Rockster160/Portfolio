Buddy::Tools.register(
  name:             :call_jil_function,
  description:      <<~TXT,
    Invoke a Jil FUNCTION task with typed args. Use when the person
    asks for something covered by a task in the `jil_functions`
    section of the live context file - anything from turning on
    lights with a color, starting the car with a destination and
    temp, adjusting a printer setting, etc.

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

    Pass args via extra k=v pairs on the marker, one per signature
    arg, using LOWERCASE_SNAKE_CASE of the arg name. Emit them IN
    SIGNATURE ORDER - some tasks read their args by position, so the
    order you write them in matters. Example:

      Signature: function("Temp" TAB Numeric BR "Dest" TAB String)
      Marker: [[propose: call_jil_function name="Tesla Start" temp=72 dest="Home"]]

    If required args are missing or ambiguous ("start the car" with
    no temp), ask the person a short follow-up. Don't guess numeric
    values. If nothing on the function list plausibly matches, tell
    them you don't have that wired.
  TXT
  args:             {
    name: { type: :string, required: true, description: "Fuzzy function-task name to call" },
    # All other k=v marker args pass through as function params. Only `name`
    # is declared; passthrough_args keeps the rest through validate_payload.
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

    # Everything the marker parser handed us EXCEPT :name is treated as
    # a function argument. String-key + string values (marker parser
    # yields strings) - the Jil executor coerces per the signature.
    fn_args = payload.except(:name).transform_keys(&:to_s)

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
    task.execute(
      input,
      auth:          :buddy,
      auth_id:       ctx.user.id,
      trigger_scope: "buddy",
    )
    { fired: true, task_id: task.id, task_name: task.name }
  },
  receipt:          ->(_result, ctx) {
    name = ctx.proposal["payload"]&.dig("task_name") || "function"
    "Called **#{name}** ✓"
  },
)
