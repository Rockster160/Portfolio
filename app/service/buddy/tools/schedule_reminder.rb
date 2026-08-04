Buddy::Tools.register(
  name:        :schedule_reminder,
  description: <<~TXT,
    Schedule a nudge to fire at a future local time. Use when the person
    says "remind me to X at Y", "at 3pm ping me about the vet appt",
    "in an hour tell me to check the oven", etc.

    A reminder arrives once and is gone. If they said "agenda", "calendar",
    or asked for a TASK, they want a row they can see and check off - that's
    `add_agenda_item`, and a reminder is not a substitute for it.

    ONE-SHOT: pass `at` (ISO-8601 datetime with timezone offset).
    Convert natural-language times ("in 30 min", "3pm", "tomorrow
    morning") into ISO using the local time in RIGHT NOW block.

    RECURRING: pass `repeat` to fire the reminder on a schedule instead
    of just once. Use for "check in with me every day at 9", "remind me
    to take the trash out every Wednesday night", etc. `repeat` accepts:
      "daily:HH:MM"                 - every day at HH:MM
      "weekdays:HH:MM"              - Mon-Fri at HH:MM
      "weekly:<weekday>:HH:MM"      - e.g. "weekly:wednesday:20:00"
      "monthly:<day-of-month>:HH:MM" - e.g. "monthly:1:09:00"
    When `repeat` is set, `at` is optional (the first fire computes
    from the recurrence). If both are set, `at` is the first fire and
    the recurrence takes over from then on.

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
    repeat: { type: :string, required: false, description: "Recurrence spec: daily:HH:MM / weekdays:HH:MM / weekly:<day>:HH:MM / monthly:<dom>:HH:MM" },
    kind:   { type: :enum,   required: false, default: :reminder, values: %i[reminder prompt] },
  },
  confirm: ->(payload, ctx) {
    # Parse recurrence spec (colon-separated) into the hash BuddyReminder
    # understands. Deliberately narrow, extend by adding another `when`.
    recurrence_hash = nil
    if payload[:repeat].to_s.strip.length > 0
      parts = payload[:repeat].to_s.strip.downcase.split(":")
      recurrence_hash = case parts.first
      when "daily"     then { "kind" => "daily",    "at" => "#{parts[1]}:#{parts[2]}" }
      when "weekdays"  then { "kind" => "weekdays", "at" => "#{parts[1]}:#{parts[2]}" }
      when "weekly"    then { "kind" => "weekly", "weekday" => parts[1], "at" => "#{parts[2]}:#{parts[3]}" }
      when "monthly"   then { "kind" => "monthly", "day" => parts[1].to_i, "at" => "#{parts[2]}:#{parts[3]}" }
      end
      raise "unknown repeat spec #{payload[:repeat].inspect}" if recurrence_hash.nil?
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

    # Refusing rather than quietly merging: if this really is a second, separate
    # thing at the same minute, silently folding it into the first would lose a
    # reminder they asked for. Told about it, Buddy can say it's already set, or
    # cancel and re-set if the wording is meant to replace it.
    if recurrence_hash.nil? && (clash = BuddyReminder.clashing(ctx.user, payload[:text], fire_at))
      raise "#{clash.body.inspect} is already set for #{when_str} - nothing new to add"
    end

    summary = if recurrence_hash
      "Repeating reminder starting #{when_str}?"
    else
      "Remind you at #{when_str}?"
    end
    { summary: summary, resolved: { fire_at_iso: fire_at.iso8601, recurrence: recurrence_hash } }
  },
  label: ->(payload, ctx) {
    fire_at  = Time.zone.parse(payload[:fire_at_iso].to_s) rescue nil
    when_str = fire_at ? fire_at.in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p") : payload[:at].to_s
    sub      = payload[:recurrence] ? "repeats #{payload[:repeat] || payload.dig(:recurrence, 'kind')}" : when_str
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
      kind:              (payload[:kind] || :reminder).to_s,
      body:              payload[:text].to_s.first(500),
      fire_at:           fire_at,
      recurrence:        payload[:recurrence],
    )
    { reminder_id: reminder.id, fire_at: fire_at.iso8601, recurrence: payload[:recurrence] }
  },
  # Scheduling a reminder is safe + reversible, so it runs WITHOUT a
  # confirmation checkbox and drops an activity receipt instead.
  auto:    true,
  receipt: ->(result, ctx) {
    name    = ctx.buddy_name
    fire_at = (Time.zone.parse(result[:fire_at].to_s) rescue nil)
    rec     = result[:recurrence]

    if rec.is_a?(Hash)
      hhmm  = (Time.zone.parse(rec["at"].to_s) rescue nil)
      tstr  = hhmm ? hhmm.strftime("%-I:%M%P").sub(":00", "") : rec["at"].to_s
      every = case rec["kind"]
      when "daily"    then "every day"
      when "weekdays" then "every weekday"
      when "weekly"   then "every #{rec["weekday"].to_s.capitalize}"
      when "monthly"  then "on day #{rec["day"]} each month"
      else                 "on a schedule"
      end
      "#{name} will remind you #{every} at #{tstr}"
    else
      "#{name} will send you a reminder #{ctx.friendly_future(fire_at)}"
    end
  },
)
