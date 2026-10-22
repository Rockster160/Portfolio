Buddy::Tools.register(
  name:             :schedule_function,
  summary:          "Run a house or car automation at a later time or after a delay: \"play the " \
                    "nap sound in 2 minutes\", \"start the car at 7:40\". A timer only counts down - " \
                    "this does the thing.",
  description:      <<~TXT,
    Put one of their Jil automations on the clock - anything in
    `jil_functions` or `jil_triggers`. Same name, same arguments or data as
    `run_jil_task` - this one just happens later.

    "Play Whisper Nap sound at 11" is this: `name: "Whisper Sound"`,
    `sound: "nap"`, `at:` eleven tonight. `run_jil_task` would play it the
    moment you called it, sixteen minutes early, in a real room (prod 3562) -
    so the second they say WHEN, this is the tool.

    ## Which of the "later" tools

      schedule_function  - a Jil automation by name, with its arguments or
                           data. This one.
      schedule_trigger   - a raw listener SCOPE (`some:jil:listener`), no
                           arguments to speak of.
      schedule_reminder  - a message for them to READ, or `text: "run <name>"`
                           for a whole saved routine.
      alarm              - it has to interrupt them, out loud, until stopped.
      remind_when        - on a CONDITION, not a clock: "once I leave",
                           "when I get home". `run` + `run_args` call the
                           same function when it happens.

    ## Arguments

    `name` and the task's own arguments (a function) or `data` (a trigger) are
    exactly what you'd pass to `run_jil_task` - read the signature or listener
    off the index the same way. The task is resolved NOW, so a
    name that matches nothing comes straight back to you while they're still
    here to say which one they meant. It's resolved AGAIN when it fires, so a
    function that's since been renamed or switched off degrades honestly
    instead of running the nearest thing to it.

      at      - when to run it (ISO datetime). Required unless `repeat` is set.
      repeat  - a recurrence, same spellings `schedule_reminder` takes
                ("daily:07:00", "weekdays:18:30", "weekly:sat:09:00"). "Every
                morning at 7, play the wake sound" is one row, not seven.
      until   - stop repeating after this date (YYYY-MM-DD).
      note    - what to put in the thread when it runs. Write it as the line
                THEY should read at that moment ("Nap sound for Whisper"), not
                as a description of the plumbing.

    ## What it will and won't do

    It runs the function and posts the receipt, with no model turn behind it -
    so it happens on time and comes out the same way every time.

    Only ever schedule a function that they ASKED to happen. A function is not
    a thing to run speculatively on a timer, and one that opens, closes, unlocks
    or starts something will do exactly that, unattended, at the hour named.

    They can see it in `upcoming_reminders` and call it off with
    `cancel_reminder`, the same as anything else on the clock.
  TXT
  feature:          :jil,
  args:             {
    name:   { type: :string, required: true,  description: "Task name, verbatim from `jil_functions` or `jil_triggers`" },
    data:   { type: :string, required: false, description: "A trigger's data, built from its listener. Omit for a function" },
    at:     { type: :string, required: false, description: "When to run it (ISO datetime). Required unless `repeat` is set." },
    repeat: { type: :string, required: false, description: "Recurrence spec, same shapes as schedule_reminder: daily:HH:MM / weekdays:HH:MM / weekly:<days>:HH:MM / monthly:<dom>:HH:MM / every:<n>-<unit>:HH:MM" },
    until:  { type: :string, required: false, description: "Stop repeating after this date (YYYY-MM-DD)" },
    note:   { type: :string, required: false, description: "The line to show in the thread when it runs, in their words" },
  },
  # Everything else passes through as the function's own arguments, exactly as
  # in run_jil_task.
  passthrough_args: true,
  auto:             true,
  confirm:          ->(payload, ctx) {
    fn_args = payload.except(:name, :at, :repeat, :until, :note, :data)

    # Resolved through run_jil_task's OWN confirm rather than a copy of it. That
    # check is not a name lookup - it is also the shape check on the arguments
    # or data, and a second implementation of it would drift from the one that
    # runs.
    Buddy::Tools[:run_jil_task][:confirm].call({ name: payload[:name], data: payload[:data] }.merge(fn_args), ctx)

    recurrence = Buddy::RepeatSpec.parse(payload[:repeat], on: ctx.user.perceived_today)
    raise "unknown repeat spec #{payload[:repeat].inspect}" if payload[:repeat].to_s.strip.present? && recurrence.nil?

    if recurrence && payload[:until].to_s.strip.present?
      ends = (Date.parse(payload[:until].to_s) rescue nil)
      raise "couldn't read #{payload[:until].inspect} as a date" if ends.nil?

      recurrence = recurrence.merge("until_on" => ends.iso8601)
    end

    fire_at   = ctx.resolve_time(payload[:at]) if payload[:at].to_s.strip.present?
    fire_at ||= BuddyReminder.new(user: ctx.user, recurrence: recurrence).next_fire_at(from: Time.current) if recurrence
    raise "couldn't work out when to run that" if fire_at.nil?
    raise "that time has already passed" if fire_at < Time.current

    when_str = Buddy::Clock.day_at(fire_at, zone: ctx.user.timezone)
    summary  = (
      if recurrence
        "Run **#{payload[:name]}** repeatedly, starting #{when_str}?"
      else
        "Run **#{payload[:name]}** at #{when_str}?"
      end
    )

    {
      summary:  summary,
      resolved: {
        fire_at_iso: fire_at.iso8601,
        recurrence:  recurrence,
        fn_args:     fn_args.transform_keys(&:to_s),
        data:        payload[:data].to_s.strip.presence,
      }.compact,
    }
  },
  label:            ->(payload, ctx) {
    fire_at = (Time.zone.parse(payload[:fire_at_iso].to_s) rescue nil)
    subs    = [payload[:recurrence] ? "repeats #{payload[:repeat]}" : Buddy::Clock.day_at(fire_at, zone: ctx.user.timezone)]
    subs << Array(payload[:fn_args]).map { |k, v| "#{k}: #{v}" }.join(", ").presence
    { title: payload[:name].to_s, sub: subs.compact_blank.join("\n").presence }
  },
  execute:          ->(payload, ctx) {
    conversation = ByteConversation.for_self_initiated(ctx.user)
    raise "no conversation to run that in" if conversation.nil?

    reminder = BuddyReminder.create!(
      user:              ctx.user,
      byte_conversation: conversation,
      kind:              :reminder,
      # The line they'll read over the receipt when it runs.
      body:              payload[:note].to_s.presence || "Running #{payload[:name]}.",
      fire_at:           Time.zone.parse(payload[:fire_at_iso].to_s),
      recurrence:        payload[:recurrence],
      # The tool NAME, never a resolved id - re-resolved every time it fires.
      action:            {
        "tool"    => "run_jil_task",
        "payload" => { "name" => payload[:name].to_s, "data" => payload[:data] }.compact.merge(payload[:fn_args] || {}),
      },
    )
    {
      reminder_id: reminder.id,
      name:        payload[:name].to_s,
      fire_at:     reminder.fire_at.iso8601,
      recurrence:  payload[:recurrence],
    }
  },
  receipt:          ->(result, ctx) {
    fire_at = (Time.zone.parse(result[:fire_at].to_s) rescue nil)
    rec     = result[:recurrence]

    if rec.is_a?(Hash)
      "#{ctx.buddy_name} will run **#{result[:name]}** #{Buddy::ReminderPresenter.repeat_phrase(rec)}"
    else
      "#{ctx.buddy_name} will run **#{result[:name]}** #{ctx.friendly_future(fire_at)}"
    end
  },
)
