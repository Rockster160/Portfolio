Buddy::Tools.register(
  name:        :schedule_reminder,
  description: <<~TXT,
    Schedule a nudge to fire at a future local time. Use when the person
    says "remind me to X at Y", "at 3pm ping me about the vet appt",
    "in an hour tell me to check the oven", etc.

    A reminder arrives once and is gone. If they said "agenda", "calendar",
    or asked for a TASK, they want a row they can see and check off - that's
    `add_agenda_item`, and a reminder is not a substitute for it.

    `notify` aims it at SOMEBODY ELSE in the house. "Send Chelsea a reminder in
    10 minutes to...", "remind Eve at 4 that...", "ping mom tonight about..." -
    name them here, and it arrives on THEIR companion at that time, framed as
    coming from the person who asked. Read who the reminder is FOR, not just
    what it says: "send a reminder to Chelsea that we need to X" is for
    Chelsea, and setting it for yourself instead means the person who was
    supposed to act never hears about it. The reminder still belongs to whoever
    asked, so they can see and cancel it. Leave `notify` off for themselves.

    This is for a nudge at a TIME. To tell someone something right now, that's
    `message_partner`.

    ONE-SHOT: pass `at` (ISO-8601 datetime with timezone offset).
    Convert natural-language times ("in 30 min", "3pm", "tomorrow
    morning") into ISO using the local time in RIGHT NOW block.

    RECURRING: pass `repeat` to fire the reminder on a schedule instead
    of just once. Use for "check in with me every day at 9", "remind me
    to take the trash out every Wednesday night", etc. `repeat` accepts:
      "daily:HH:MM"                  - every day at HH:MM
      "weekdays:HH:MM"               - Mon-Fri at HH:MM
      "weekly:<days>:HH:MM"          - "weekly:wednesday:20:00", and more
                                       than one is fine: "weekly:mon,wed,fri:07:30"
      "monthly:<day-of-month>:HH:MM" - e.g. "monthly:1:09:00"
      "monthly:<nth>-<weekday>:HH:MM" - the Nth weekday of the month, where
                                       nth is 1-4 or "last": "monthly:2-tuesday:10:00"
                                       is the SECOND TUESDAY of every month
      "every:<n>-<unit>:HH:MM"       - every N days / weeks / months, counting
                                       from today: "every:2-weeks:10:00" is
                                       every OTHER week on today's weekday
      "yearly:HH:MM"                 - once a year, on today's date

    "Every second Tuesday" is two different requests and they aren't the
    same days - the second Tuesday OF THE MONTH is
    "monthly:2-tuesday:HH:MM", every OTHER Tuesday is "every:2-weeks:HH:MM"
    set on a Tuesday. Ask which they meant if it isn't clear.

    When `repeat` is set, `at` is optional (the first fire computes
    from the recurrence). If both are set, `at` is the first fire and
    the recurrence takes over from then on. `until` (a plain date,
    YYYY-MM-DD) stops it repeating after that day.

    `kind` controls what happens at fire time:
      "reminder" (default) - plain text nudge + push notification.
      "prompt" - fresh Buddy turn triggered with `text` as the seed.
        Use for "check in with me every day at 9" where you want Buddy
        to compose a fresh check-in each time, not repeat the exact
        same words.

    A reminder can also RUN something instead of saying it. Write `text` as
    "run <name>" (or trigger / fire / start) naming one of their saved routines
    or a Jil task, and that's what happens when it comes due - no message, just
    the thing. "Every weekday at 7, run my morning routine" is this. It's
    resolved when it FIRES, so a name that stops matching quietly goes back to
    being an ordinary nudge rather than running the nearest thing to it.
  TXT
  args: {
    text:   { type: :string, required: true,  description: "What to remind them of / prompt about" },
    at:     { type: :string, required: false, description: "First fire time (ISO datetime). Required for one-shot." },
    repeat: { type: :string, required: false, description: "Recurrence spec: daily:HH:MM / weekdays:HH:MM / weekly:<days>:HH:MM / monthly:<dom>:HH:MM / monthly:<nth>-<weekday>:HH:MM / every:<n>-<unit>:HH:MM / yearly:HH:MM" },
    until:  { type: :string, required: false, description: "Stop repeating after this date (YYYY-MM-DD)" },
    kind:   { type: :enum,   required: false, default: :reminder, values: %i[reminder prompt] },
    notify: { type: :string, required: false, description: "Household member this reminder is FOR, if not the person asking" },
  },
  confirm: ->(payload, ctx) {
    recurrence_hash = Buddy::RepeatSpec.parse(payload[:repeat], on: ctx.user.perceived_today)
    if payload[:repeat].to_s.strip.present? && recurrence_hash.nil?
      raise "unknown repeat spec #{payload[:repeat].inspect}"
    end

    if recurrence_hash && payload[:until].to_s.strip.present?
      ends = (Date.parse(payload[:until].to_s) rescue nil)
      raise "couldn't read #{payload[:until].inspect} as a date" if ends.nil?

      recurrence_hash = recurrence_hash.merge("until_on" => ends.iso8601)
    end

    fire_at = ctx.resolve_time(payload[:at]) if payload[:at].to_s.strip.length > 0
    # If recurring and no explicit `at`, compute the first fire from the
    # recurrence spec.
    if fire_at.nil? && recurrence_hash
      dummy = BuddyReminder.new(user: ctx.user, recurrence: recurrence_hash)
      fire_at = dummy.next_fire_at(from: Time.current)
    end
    raise "couldn't determine a fire time" if fire_at.nil?
    raise "fire time is in the past" if fire_at < Time.current

    when_str = fire_at.in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p")

    # Who it's FOR. Naming someone we can't place is refused rather than
    # quietly aimed back at the asker - a reminder that reaches the wrong
    # person is the failure this argument exists to stop (prod 2547).
    wanted      = payload[:notify].to_s.strip
    recipient   = wanted.present? ? ctx.resolve_household_user(wanted) : nil
    raise "I'm not sure who #{wanted} is" if wanted.present? && recipient.nil?

    notify_user = recipient && recipient.id != ctx.user.id ? recipient : nil

    # Refusing rather than quietly merging: if this really is a second, separate
    # thing at the same minute, silently folding it into the first would lose a
    # reminder they asked for. Told about it, Buddy can say it's already set, or
    # cancel and re-set if the wording is meant to replace it.
    if recurrence_hash.nil? && notify_user.nil? && (clash = BuddyReminder.clashing(ctx.user, payload[:text], fire_at))
      raise "#{clash.body.inspect} is already set for #{when_str} - nothing new to add"
    end

    who = notify_user ? notify_user.first_name : "you"
    summary = if recurrence_hash
      "Repeating reminder for #{who} starting #{when_str}?"
    else
      "Remind #{who} at #{when_str}?"
    end
    {
      summary:  summary,
      resolved: {
        fire_at_iso:    fire_at.iso8601,
        recurrence:     recurrence_hash,
        notify_user_id: notify_user&.id,
        recipient_name: notify_user&.first_name,
      }.compact,
    }
  },
  label: ->(payload, ctx) {
    fire_at  = Time.zone.parse(payload[:fire_at_iso].to_s) rescue nil
    when_str = fire_at ? fire_at.in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p") : payload[:at].to_s
    sub      = payload[:recurrence] ? "repeats #{payload[:repeat] || payload.dig(:recurrence, 'kind')}" : when_str
    sub      = "for #{payload[:recipient_name]} · #{sub}" if payload[:recipient_name].present?
    { title: payload[:text].to_s.truncate(60), sub: sub.presence }
  },
  execute: ->(payload, ctx) {
    fire_at = Time.zone.parse(payload[:fire_at_iso].to_s) || ctx.resolve_time(payload[:at])
    conversation = ctx.user.byte_conversations.where(mode: :buddy).order(last_message_at: :desc).first ||
                   ctx.user.byte_conversations.order(last_message_at: :desc).first
    raise "no conversation to fire into" if conversation.nil?

    reminder = BuddyReminder.create!(
      user:              ctx.user,
      byte_conversation: conversation,
      notify_user_id:    payload[:notify_user_id],
      kind:              (payload[:kind] || :reminder).to_s,
      body:              payload[:text].to_s.first(500),
      fire_at:           fire_at,
      recurrence:        payload[:recurrence],
    )
    {
      reminder_id:    reminder.id,
      fire_at:        fire_at.iso8601,
      recurrence:     payload[:recurrence],
      recipient_name: payload[:recipient_name],
    }
  },
  # Scheduling a reminder is safe + reversible, so it runs WITHOUT a
  # confirmation checkbox and drops an activity receipt instead.
  auto:    true,
  # Who it's for leads the receipt when it isn't them. "Byte will send you a
  # reminder at 12:22pm" was the only visible sign that a reminder meant for
  # Chelsea had been aimed back at the person who asked, and it's easy to read
  # past (prod 2547).
  receipt: ->(result, ctx) {
    name    = ctx.buddy_name
    fire_at = (Time.zone.parse(result[:fire_at].to_s) rescue nil)
    rec     = result[:recurrence]
    who     = result[:recipient_name].presence

    if rec.is_a?(Hash)
      hhmm  = (Time.zone.parse(rec["at"].to_s) rescue nil)
      tstr  = hhmm ? hhmm.strftime("%-I:%M%P").sub(":00", "") : rec["at"].to_s
      ends  = rec["until_on"].present? ? " until #{rec["until_on"]}" : ""
      "#{name} will remind #{who || "you"} #{Buddy::ReminderPresenter.repeat_phrase(rec)} at #{tstr}#{ends}"
    elsif who
      "#{name} will remind #{who} #{ctx.friendly_future(fire_at)}"
    else
      "#{name} will send you a reminder #{ctx.friendly_future(fire_at)}"
    end
  },
)
