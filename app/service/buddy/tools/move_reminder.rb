Buddy::Tools.register(
  name:        :move_reminder,
  description: <<~TXT,
    Change WHEN a reminder fires, and optionally reword it. Use for "move the
    tomato reminder to 3", "make that an hour later", "change the dryer one to
    2:15", "actually remind me about it tomorrow morning".

    This also SNOOZES one that just went off. "Send me that again tomorrow at
    6", "remind me about this later", "not now, push it an hour" - said in
    reply to a reminder landing - all mean this, with `match` taken from the
    text of the reminder they're answering. Re-arming the one they're looking at
    is right; making a fresh one from scratch loses whatever else was on it.

    Reach for this instead of `schedule_reminder` any time the thing they're
    talking about already exists. Setting a second one leaves the first alive,
    so the original still goes off at the hour they just told you was wrong -
    which is the whole reason they asked.

    `match` is a substring of the reminder text or its numeric id from
    `upcoming_reminders`. `at` is the new time as an ISO-8601 datetime with
    offset; convert "3pm" / "an hour later" / "tomorrow morning" using the local
    time in the RIGHT NOW block. For a repeating reminder the clock time is
    taken from `at` and the recurrence keeps its shape - a daily 9am moved to
    9:30 is still daily.

    This is for a reminder on a CLOCK. A condition-based watch has no time to
    move; cancel it and set a new one.
  TXT
  args: {
    match: { type: :string, required: true,  description: "Substring of the reminder text, or its numeric id" },
    at:    { type: :string, required: true,  description: "New fire time (ISO-8601 datetime with offset)" },
    text:  { type: :string, required: false, description: "New wording, only if they changed what it should say" },
  },
  # Matches whatever is pending right now, which is never the same set twice.
  routinable: false,
  confirm: ->(payload, ctx) {
    needle = payload[:match].to_s.strip
    # Pending FIRST, then anything that went off in the last few hours. A
    # one-shot stamps `fired_at` and drops out of `pending` the moment it
    # lands, and the moment it lands is exactly when someone says "send me that
    # again tomorrow at 6" - so the old lookup answered the most natural snooze
    # there is with "couldn't find that reminder to move it" (prod 2364), and
    # the whole thing had to be dictated a second time.
    scope  = BuddyReminder.where(user_id: ctx.user.id, cancelled_at: nil)
    recent = scope.where(fired_at: nil).or(scope.where(fired_at: Buddy::Tools::SNOOZE_WINDOW.ago..))

    reminder = if needle.match?(/\A\d+\z/)
      recent.find_by(id: needle.to_i)
    else
      # Still-pending ones win a tie: a daily that fired this morning and a
      # one-off tonight can share a word, and the live one is what they mean.
      matches = recent.where("LOWER(body) LIKE ?", "%#{needle.downcase}%").order(:fire_at).to_a
      matches.find { |r| r.fired_at.nil? } || matches.first
    end
    raise "no reminder matching #{needle.inspect}" if reminder.nil?

    fire_at = ctx.resolve_time(payload[:at])
    raise "couldn't work out the new time" if fire_at.nil?
    raise "that time has already gone by" if fire_at < Time.current

    zoned    = fire_at.in_time_zone(ctx.user.timezone)
    when_str = zoned.strftime("%a %-I:%M %p")
    # A recurring reminder keeps its shape and only the hour moves, so the
    # recurrence carries the new HH:MM and `fire_at` is recomputed from it.
    recurrence = (reminder.recurrence.merge("at" => zoned.strftime("%H:%M")) if reminder.recurring?)

    {
      summary:  "Move #{reminder.body.truncate(40).inspect} to #{when_str}?",
      resolved: {
        reminder_id: reminder.id,
        fire_at_iso: fire_at.iso8601,
        recurrence:  recurrence,
        was:         reminder.fire_at.in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p"),
      },
    }
  },
  label: ->(payload, ctx) {
    fire_at  = Time.zone.parse(payload[:fire_at_iso].to_s) rescue nil
    when_str = fire_at ? fire_at.in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p") : payload[:at].to_s
    reminder = BuddyReminder.find_by(id: payload[:reminder_id])
    { title: (reminder&.body).to_s.truncate(60), sub: "moved to #{when_str}" }
  },
  execute: ->(payload, ctx) {
    reminder = BuddyReminder.where(user_id: ctx.user.id).find(payload[:reminder_id])
    # Clearing `fired_at` is what makes a snooze a snooze: a one-shot that
    # already went off is terminal, and a new `fire_at` on its own would sit
    # there being ignored by the firer.
    attrs    = { fire_at: Time.zone.parse(payload[:fire_at_iso].to_s), fired_at: nil }
    attrs[:recurrence] = payload[:recurrence] if payload[:recurrence].present?
    attrs[:body]       = payload[:text].to_s.first(500) if payload[:text].to_s.strip.present?
    reminder.update!(attrs)

    { reminder_id: reminder.id, fire_at: reminder.fire_at.iso8601, was: payload[:was], body: reminder.body }
  },
  # Moving a nudge is as safe and reversible as setting one, so it matches
  # schedule_reminder: it runs on the spot with a receipt rather than a checkbox.
  auto:    true,
  receipt: ->(result, ctx) {
    fire_at = (Time.zone.parse(result[:fire_at].to_s) rescue nil)
    "#{ctx.buddy_name} moved that reminder to #{ctx.friendly_future(fire_at)}"
  },
)
