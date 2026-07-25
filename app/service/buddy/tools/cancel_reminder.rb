Buddy::Tools.register(
  name:        :cancel_reminder,
  description: <<~TXT,
    Cancel a pending reminder the user previously scheduled. Use when
    the person says "actually nevermind that reminder", "don't remind
    me about X anymore", "cancel the vet reminder". `match` is a
    substring of the reminder body OR the reminder id if you can see
    it in `upcoming_reminders`.
  TXT
  args: {
    match: { type: :string, required: true, description: "Substring to match, or numeric reminder id" },
  },
  confirm: ->(payload, ctx) {
    needle = payload[:match].to_s.strip
    scope = BuddyReminder.pending.where(user_id: ctx.user.id)
    reminder = if needle.match?(/\A\d+\z/)
      scope.find_by(id: needle.to_i)
    else
      scope.where("LOWER(body) LIKE ?", "%#{needle.downcase}%").order(:fire_at).first
    end
    raise "no matching pending reminder" if reminder.nil?

    when_str = reminder.fire_at.in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p")
    {
      summary:  "Cancel the reminder for #{when_str}: #{reminder.body.truncate(50)}?",
      resolved: { reminder_id: reminder.id },
    }
  },
  label: ->(payload, _ctx) {
    r = BuddyReminder.find_by(id: payload[:reminder_id])
    r ? "Cancel: #{r.body.truncate(50)}" : "Cancel reminder"
  },
  execute: ->(payload, _ctx) {
    reminder = BuddyReminder.find(payload[:reminder_id])
    reminder.update!(cancelled_at: Time.current)
    { reminder_id: reminder.id }
  },
  receipt: ->(_result, _ctx) { "Reminder cancelled ✓" },
)
