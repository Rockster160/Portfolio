Buddy::Tools.register(
  name:        :set_command,
  summary:     "\"Set <button> to <something>\": choose what one of their automations does when it " \
               "runs - a button, a switch - by filling the key it leaves for you.",
  roster:      ->(user) { Buddy::Commands.roster(user) },
  description: <<~TXT,
    Some of their automations leave a key for you to fill: the task calls
    `Buddy.command("<key>")`, and whatever is saved under that key runs each
    time the task does. "Set the bathroom button to turn off the lights" saves
    turning off the lights under **Bathroom Button**, so the next press does
    that. The keys, and what each does now, are listed after this tool's
    summary. `key` is one of them - match it loosely against what they called
    it, and if none fits, say which keys exist rather than guessing.

    Two ways to fill it, and the first is the one to reach for:

    - **`steps`** - the tool calls that do what they asked, as a JSON array of
      `{"tool_name": "...", "payload": {...}}`, exactly as `save_routine` takes
      them. "Turn off the lights" is
      `[{"tool_name":"run_jil_task","payload":{"name":<their lights-off task>}}]`.
      These run the moment the automation does, with nothing in between, and
      they're checked now, so a name that matches nothing comes back to you
      while they can still tell you which one they meant. `capture_last`
      instead saves the last N things you just did for them ("set the button
      to that").
    - **`say`** - their words, saved as they said them, and handed back to you
      as a fresh request every time the automation runs. Only for what can't be
      pinned to fixed calls ahead of time: something that depends on how
      things are at that moment ("close whichever garage door is open"),
      something that needs you to look and decide, or something to say that
      should be new each time ("tell me something encouraging").

    One or the other, never both. Saving again over a key REPLACES what was
    there. `clear: true` empties it, so the automation does nothing extra.
  TXT
  feature:     :jil,
  args:        {
    key:          { type: :string,  required: true,  description: "The key to fill, from the list after the summary" },
    steps:        { type: :string,  required: false, description: "JSON array of {tool_name, payload}, in order" },
    capture_last: { type: :integer, required: false, description: "Save the last N things you just did, instead of `steps`" },
    say:          { type: :string,  required: false, description: "Their words, to be handled as a fresh request each time. Only when steps can't do it" },
    clear:        { type: :boolean, required: false, description: "True to empty the key" },
  },
  level:       1,
  routinable:  false,
  merge_key:   ->(payload) { "set_command:#{payload[:key].to_s.downcase.strip}" },
  supersedes:  true,
  confirm:     ->(payload, ctx) {
    slot = Buddy::Commands.slot(ctx.user, payload[:key])
    if slot.nil?
      keys = Buddy::Commands.slots(ctx.user).pluck(:name)
      raise "no automation calls Buddy.command(#{payload[:key].to_s.inspect})" if keys.empty?

      raise "#{payload[:key].to_s.inspect} isn't a key - the ones their automations have are #{keys.to_sentence}"
    end

    if ActiveModel::Type::Boolean.new.cast(payload[:clear])
      next { summary: "Clear **#{slot[:name]}**?", resolved: { key: slot[:name], clear: true } }
    end

    words = payload[:say].to_s.strip.presence
    given = [payload[:steps].present?, payload[:capture_last].present?, words.present?].count(true)
    raise "fill #{slot[:name]} with `steps`, `capture_last` or `say`" if given.zero?
    raise "fill #{slot[:name]} with ONE of `steps`, `capture_last` or `say`" if given > 1

    next { summary: "Set **#{slot[:name]}**?", resolved: { key: slot[:name], say: words } } if words

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
    steps = Buddy::Routines.sanitize(rows, ctx)

    # A step that runs the very task holding this key would press the button
    # again from inside its own press.
    own = slot[:tasks].map(&:downcase)
    looping = steps.find { |step| own.include?(step.dig("payload", "name").to_s.downcase) }
    if looping
      raise "#{looping.dig("payload", "name")} is the automation that runs #{slot[:name]}, so it can't " \
            "be one of its steps"
    end

    { summary: "Set **#{slot[:name]}**?", resolved: { key: slot[:name], steps: steps } }
  },
  label:       ->(payload, _ctx) {
    sub = (
      if payload[:clear]
        "does nothing extra"
      elsif payload[:say].present?
        "say to Buddy: \"#{payload[:say]}\""
      else
        Array(payload[:steps]).map { |s| BuddyRoutine.step_phrase(s) }.join("\n")
      end
    )
    { title: payload[:key].to_s, sub: sub.presence }
  },
  execute:     ->(payload, ctx) {
    key = payload[:key].to_s
    cmd = BuddyCommand.named(ctx.user, key)

    if payload[:clear]
      cmd&.destroy!
      next { key: key, cleared: true }
    end

    cmd ||= ctx.user.buddy_commands.new
    cmd.update!(name: key, steps: Array(payload[:steps]), say: payload[:say].presence)
    { key: cmd.name, summary: cmd.summary }
  },
  receipt:     ->(result, _ctx) {
    next "Cleared **#{result[:key]}** ✓" if result[:cleared]

    "Set **#{result[:key]}** ✓"
  },
)
