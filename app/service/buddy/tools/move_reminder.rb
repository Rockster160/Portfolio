Buddy::Tools.register(
  name:        :move_reminder,
  description: <<~TXT,
    Change WHEN a reminder they already have fires, and optionally reword it.
    Use for "move the tomato reminder to 3", "make that an hour later", "change
    the dryer one to 2:15", "actually remind me about it tomorrow morning".

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
    pending = BuddyReminder.pending.where(user_id: ctx.user.id)

    reminder = if needle.match?(/\A\d+\z/)
      pending.find_by(id: needle.to_i)
    else
      pending.where("LOWER(body) LIKE ?", "%#{needle.downcase}%").order(:fire_at).first
    end
    raise "no pending reminder matching #{needle.inspect}" if reminder.nil?

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
    attrs    = { fire_at: Time.zone.parse(payload[:fire_at_iso].to_s) }
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
