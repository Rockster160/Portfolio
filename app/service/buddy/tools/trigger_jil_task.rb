Buddy::Tools.register(
  name:        :trigger_jil_task,
  description: <<~TXT,
    Fire a Jil automation by name. Use this when the person asks for
    something that maps to one of the tasks in the `jil_triggers`
    section of the live context file - scenes ("chill mode", "good
    morning"), fans, lights, or any other task on that list.

    Each entry is `{ id, name, scope, listener, description }`. READ
    THE DESCRIPTION - names are terse and mechanical ("Great Fan",
    "ESP Button") while the description says what it actually does.
    Match on what the person wants, not on name similarity.

    `name` must be the entry's `name` verbatim.

    ## Passing data

    `listener` is the match pattern. When it is a bare word
    (`fan-high`) the task fires with no data - omit `data` entirely.

    When it has colons, everything after the scope is a FILTER the data
    has to satisfy. Supply matching `data` or the task will NOT run.

    Format: space-separated `key:value` pairs. EVERY piece must have a
    colon - mixing a bare word in ("add name:X") silently parses wrong
    and nothing fires.

    Reading a listener:
      * `scope:word`      - a bare word is a VALUE the data must contain.
                            Pair it with its natural key, almost always
                            `action`. So `event:add` -> `action:add`.
      * `scope:key::Value` - that key must equal Value. Send `key:Value`.

    Worked examples:

      listener: `event:add name::Transaction`
      marker:   [[propose: trigger_jil_task name="Transaction Categorize Prompt" data="action:add name:Transaction"]]

      listener: `hass-button:device_name::"Laundry Button"`
      marker:   [[propose: trigger_jil_task name="Laundry Button" data="device_name:Laundry Button"]]

      listener: `fan-high`
      marker:   [[propose: trigger_jil_task name="Fan High"]]

    If a value itself contains spaces or colons, send `data` as a JSON
    object instead - that is accepted too:

      data='{"name":"Tech Stand-Up: Daily","action":"add"}'

    If the listener filters on something you cannot work out from what
    the person said, ask a short follow-up rather than guessing. If
    nothing on the list plausibly matches, say you do not have a task
    wired for it - do not stretch a near-miss.

    The list only contains tasks the person allowed you to run, and may
    include tasks shared with them by someone else (those run under the
    owner's account).
  TXT
  args: {
    name: { type: :string, required: true,  description: "Task name to fire, verbatim from the index" },
    data: { type: :string, required: false, description: "Colon-separated key:value data the listener filters on. Omit for bare-scope tasks." },
  },
  confirm: ->(payload, ctx) {
    q = payload[:name].to_s.downcase.strip
    candidates = ctx.user.accessible_tasks.buddy_visible.where.not(listener: [nil, ""])
      .pluck(:id, :name, :listener)
      .reject { |_, _, listener| listener.to_s.match?(/(^|\s)function\(/i) }

    match = candidates.find { |_, n, _| n.downcase == q } ||
            candidates.find { |_, n, _| n.downcase.start_with?(q) } ||
            candidates.find { |_, n, _| n.downcase.include?(q) }

    raise "no Jil task matches #{payload[:name].inspect}" if match.nil?

    id, name, listener = match
    scope = listener.to_s.strip.split(":").first
    data  = payload[:data].to_s.strip.presence

    summary = if data
      "Fire **#{name}**? (`#{scope}` with `#{data}`)"
    else
      "Fire **#{name}**? (scope: `#{scope}`)"
    end
    { summary: summary, resolved: { task_id: id, task_name: name, scope: scope, data: data } }
  },
  label: ->(payload, _ctx) {
    title = (payload[:task_name] || payload[:name]).to_s
    subs = ["scope: #{payload[:scope] || '?'}"]
    subs << "data: #{payload[:data]}" if payload[:data].present?
    { title: title, sub: subs.join("\n") }
  },
  execute: ->(payload, ctx) {
    # Same shape as the `trigger <scope>:<key>:<value>` command - scope plus
    # parsed data. Fires the SCOPE, so anything else the person can reach on
    # it and whose filter the data satisfies runs too, exactly like any other
    # trigger source. auth_id records WHO asked; each resulting Execution runs
    # as its own task's owner, so (execution.user_id, auth_type_id) is the
    # on-behalf-of trail.
    data = payload[:data].present? ? ::Tokenizing::TriggerData.parse(payload[:data], as: ctx.user) : {}
    ::Jil.trigger(ctx.user, payload[:scope].to_sym, data, auth: :buddy, auth_id: ctx.user.id)
    { fired: true, task_id: payload[:task_id], scope: payload[:scope], data: payload[:data] }
  },
  receipt: ->(_result, ctx) {
    name = ctx.proposal["payload"]&.dig("task_name") || "task"
    "Fired **#{name}** ✓"
  },
)
