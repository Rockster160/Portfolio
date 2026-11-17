Buddy::Tools.register(
  name:        :set_command,
  summary:     "\"Set <button> to <something>\": choose what one of their automations does when it " \
               "runs - a button, a switch - by filling the key it leaves for you.",
  roster:      ->(user) { Buddy::Commands.roster(user) },
  description: <<~TXT,
    Some of their automations leave a key for you to fill: the task calls
    `Buddy.command("<key>")`, and the items saved under that key run each time
    the task does. The keys, and what each does now, are listed after this
    tool's summary; match `key` loosely against what they called it, and if
    none fits, say which keys exist rather than guessing.

    `items` is a JSON array, in order, of `{"tool_name": "...", "payload": {...}}`
    exactly as `save_routine` takes steps. Build it from their real tasks and
    functions, with the arguments that do what they asked, whenever those can
    do it: saved calls run the instant the automation does, with no model in
    between. Read each candidate's options before deciding a request needs
    more than that - one whose options already cover the action covers it.

    Only when the action can't be fixed ahead of time - what to act on, or
    what to say, depends on how things stand at the moment it runs, or nothing
    they have can do it - use
    `{"tool_name":"ask_buddy","payload":{"text":<their words>}}`, which hands
    the words back to you as a fresh request on every run.

    Saving again REPLACES what was there; an empty array `[]` clears it.
  TXT
  feature:     :jil,
  args:        {
    key:   { type: :string, required: true, description: "The key to fill, from the list after the summary" },
    items: { type: :string, required: true, description: "JSON array of {tool_name, payload}, in order; [] clears it" },
  },
  level:       1,
  routinable:  false,
  merge_key:   ->(payload) { "set_command:#{payload[:key].to_s.downcase.strip}" },
  supersedes:  true,
  confirm:     ->(payload, ctx) {
    key = Buddy::Commands.key(ctx.user, payload[:key])
    if key.nil?
      keys = Buddy::Commands.keys(ctx.user)
      raise "no automation calls Buddy.command(#{payload[:key].to_s.inspect})" if keys.empty?

      raise "#{payload[:key].to_s.inspect} isn't a key - the ones their automations have are #{keys.to_sentence}"
    end

    rows = Buddy::Routines.parse_rows(payload[:items]).map { |row| row.to_h.deep_stringify_keys }
    asks, tools = rows.partition { |row| row["tool_name"] == Buddy::Commands::ASK }
    raise "an ask_buddy item needs its `text`" if asks.any? { |row| row.dig("payload", "text").blank? }

    steps = tools.any? ? Buddy::Routines.sanitize(tools, ctx).each : [].each
    items = rows.map { |row| row["tool_name"] == Buddy::Commands::ASK ? row.slice("tool_name", "payload") : steps.next }
    { summary: "Set **#{key}**?", resolved: { key: key, items: items } }
  },
  label:       ->(payload, _ctx) {
    lines = Array(payload[:items]).map { |item| Buddy::Commands.phrase(item.to_h.deep_stringify_keys) }
    { title: payload[:key].to_s, sub: lines.join("\n").presence || "does nothing extra" }
  },
  execute:     ->(payload, ctx) {
    Buddy::Commands.save!(ctx.user, payload[:key].to_s, Array(payload[:items]))
    { key: payload[:key].to_s, cleared: Array(payload[:items]).empty? }
  },
  receipt:     ->(result, _ctx) { result[:cleared] ? "Cleared **#{result[:key]}** ✓" : "Set **#{result[:key]}** ✓" },
)
