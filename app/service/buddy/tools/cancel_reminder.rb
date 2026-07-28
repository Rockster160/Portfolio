Buddy::Tools.register(
  name:        :cancel_reminder,
  description: <<~TXT,
    Cancel a pending reminder OR a condition-based watch the user
    previously set. Use when the person says "actually nevermind that
    reminder", "don't remind me about X anymore", "cancel the vet
    reminder", "forget reminding me to floss". `match` is a substring of
    the reminder/watch text OR its numeric id if you can see it in
    `upcoming_reminders` / `active_watches`.
  TXT
  args: {
    match: { type: :string, required: true, description: "Substring to match, or numeric id" },
  },
  confirm: ->(payload, ctx) {
    needle = payload[:match].to_s.strip
    numeric = needle.match?(/\A\d+\z/)

    reminders = BuddyReminder.pending.where(user_id: ctx.user.id)
    watches   = BuddyWatch.active.where(user_id: ctx.user.id)

    reminder = if numeric
      reminders.find_by(id: needle.to_i)
    else
      reminders.where("LOWER(body) LIKE ?", "%#{needle.downcase}%").order(:fire_at).first
    end

    watch = if reminder
      nil
    elsif numeric
      watches.find_by(id: needle.to_i)
    else
      watches.where("LOWER(body) LIKE ?", "%#{needle.downcase}%").order(:created_at).first
    end

    raise "no matching pending reminder or watch" if reminder.nil? && watch.nil?

    if reminder
      when_str = reminder.fire_at.in_time_zone(ctx.user.timezone).strftime("%a %-I:%M %p")
      {
        summary:  "Cancel the reminder for #{when_str}: #{reminder.body.truncate(50)}?",
        resolved: { record_type: "reminder", record_id: reminder.id },
      }
    else
      human = watch.metadata.is_a?(Hash) ? watch.metadata["human_when"].to_s.presence : nil
      {
        summary:  "Cancel the reminder #{human || 'watch'}: #{watch.body.truncate(50)}?",
        resolved: { record_type: "watch", record_id: watch.id },
      }
    end
  },
  label: ->(payload, _ctx) {
    record = payload[:record_type].to_s == "watch" ? BuddyWatch.find_by(id: payload[:record_id]) : BuddyReminder.find_by(id: payload[:record_id])
    record ? "Cancel #{record.body.to_s.truncate(55)}" : "Cancel reminder"
  },
  execute: ->(payload, _ctx) {
    record = payload[:record_type].to_s == "watch" ? BuddyWatch.find(payload[:record_id]) : BuddyReminder.find(payload[:record_id])
    record.update!(cancelled_at: Time.current)
    { record_type: payload[:record_type], record_id: record.id }
  },
  receipt: ->(_result, _ctx) { "Reminder cancelled ✓" },
)
