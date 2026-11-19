Buddy::Tools.register(
  name:        :set_command,
  summary:     "\"Set <button> to <something>\", \"program button 9 to ...\", \"when I say X, do Y\": " \
               "choose what one of their buttons, phrases or automations does when it runs.",
  roster:      ->(user) { Buddy::Commands.roster(user) },
  description: <<~TXT,
    Some of their automations leave a key for you to fill: the task calls
    `Buddy.command("<key>")`, and the items saved under that key run each time
    the task does. The keys, and what each does now, are listed after this
    tool's summary; match `key` loosely against what they called it, and if
    none fits, say which keys exist rather than guessing.

    A button or phrase with no key yet gets one here too. Pass `button` with
    the button's name, and `press` when it's only a single, double or hold
    press; `phrase` for words they'll say to Jarvis; or a Jil `listener` for
    anything else. `key` is then the name to give it ("Button 9"). That makes
    a Jil task which runs the key whenever it fires, and fills it. The buttons
    that have been pressed are listed after the summary as "button <name>":
    "button 9" is the one named Btn#9. A button not listed has never been
    pressed, and has to be pressed once before it can be set.

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

    Saving REPLACES what was there; an empty array `[]` clears it. When
    they want it to do something more as well ("also", "and"), pass
    `add: true` with only the new items, and they go after what's there. A
    replace that keeps some of what's there passes those items with every
    argument shown for them after the summary.
  TXT
  feature:     :jil,
  args:        {
    key:      { type: :string, required: true, description: "The key to fill, from the list after the summary, or the name for a new one" },
    items:    { type: :string, required: true, description: "JSON array of {tool_name, payload}, in order; [] clears it" },
    add:      { type: :boolean, required: false, description: "true puts the items after what's already there instead of replacing it" },
    button:   { type: :string, required: false, description: "A button's name, from the list after the summary" },
    press:    { type: :string, required: false, description: "single, double or hold; omit for any press" },
    phrase:   { type: :string, required: false, description: "Words said to Jarvis that should run it" },
    listener: { type: :string, required: false, description: "A Jil listener, for anything that isn't a button or phrase" },
  },
  level:       1,
  routinable:  false,
  merge_key:   ->(payload) { "set_command:#{payload[:key].to_s.downcase.strip}" },
  supersedes:  true,
  confirm:     ->(payload, ctx) {
    trigger = Buddy::Commands.listener_for(
      ctx.user,
      button:   payload[:button],
      press:    payload[:press],
      phrase:   payload[:phrase],
      listener: payload[:listener],
    )
    # A trigger that already runs a key fills that key, whatever they called
    # it this time; one that doesn't makes a new key under the name given.
    key = trigger ? Buddy::Commands.key_on(ctx.user, trigger) : Buddy::Commands.key(ctx.user, payload[:key])
    if trigger && key.nil?
      key = payload[:key].to_s.squish
      raise "a new key needs a name" if key.blank?
      raise "a key can't have quotes or backslashes in it" if key.match?(/["\\]/)
      if Buddy::Commands.key(ctx.user, key)
        raise "#{key} already runs from something else - give this one its own name"
      end

      created = trigger
    end
    if key.nil?
      keys = Buddy::Commands.keys(ctx.user)
      none = "no automation calls Buddy.command(#{payload[:key].to_s.inspect})"
      raise "#{none} - name a button, phrase or listener to make one" if keys.empty?

      raise "#{payload[:key].to_s.inspect} isn't a key - the ones their automations have are #{keys.to_sentence}"
    end

    rows = Buddy::Routines.parse_rows(payload[:items]).map { |row| row.to_h.deep_stringify_keys }
    asks, tools = rows.partition { |row| row["tool_name"] == Buddy::Commands::ASK }
    raise "an ask_buddy item needs its `text`" if asks.any? { |row| row.dig("payload", "text").blank? }

    steps = tools.any? ? Buddy::Routines.sanitize(tools, ctx).each : [].each
    items = rows.map { |row| row["tool_name"] == Buddy::Commands::ASK ? row.slice("tool_name", "payload") : steps.next }
    items = Buddy::Commands.items(ctx.user, key) + items if ActiveModel::Type::Boolean.new.cast(payload[:add])
    {
      summary:  "Set **#{key}**?",
      resolved: { key: key, items: items, new_listener: created },
    }
  },
  label:       ->(payload, _ctx) {
    lines = Array(payload[:items]).map { |item| Buddy::Commands.phrase(item.to_h.deep_stringify_keys) }
    on = Buddy::Commands.trigger_phrase(payload[:new_listener].to_s) if payload[:new_listener].present?
    lines.unshift("when #{on}") if on
    { title: payload[:key].to_s, sub: lines.join("\n").presence || "does nothing extra" }
  },
  execute:     ->(payload, ctx) {
    if payload[:new_listener].present?
      Buddy::Commands.create!(ctx.user, payload[:key].to_s, payload[:new_listener])
    end
    Buddy::Commands.save!(ctx.user, payload[:key].to_s, Array(payload[:items]))
    { key: payload[:key].to_s, cleared: Array(payload[:items]).empty? }
  },
  receipt:     ->(result, _ctx) { result[:cleared] ? "Cleared **#{result[:key]}** ✓" : "Set **#{result[:key]}** ✓" },
)
