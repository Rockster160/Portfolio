Buddy::Tools.register(
  name:        :set_timer,
  description: <<~TXT,
    Start a countdown timer that shows in your window and alarms when it's up.
    Use for "set a timer for 5 minutes", "10 minute timer for the pasta", "ping
    me in 90 seconds". Convert the duration to whole SECONDS. Give a short
    `label` when the person names what it's for ("pasta", "tea"); omit it
    otherwise. This is for short countdowns the person actively watches - for a
    nudge at a specific clock time, or a recurring one, use schedule_reminder.
  TXT
  args:        {
    seconds: { type: :integer, required: true,  description: "Countdown length in whole seconds" },
    label:   { type: :string,  required: false, description: "Short name for what the timer is for" },
  },
  # Level 1 (auto): setting a timer is safe + reversible (swipe it away), so it
  # fires immediately with an activity receipt rather than a confirm checkbox.
  auto:        true,
  confirm:     ->(_payload, _ctx) { { summary: "Set a timer", resolved: {} } },
  label:       ->(payload, _ctx) { "Timer · #{Buddy::Timers.humanize_seconds(payload[:seconds])}" },
  execute:     ->(payload, ctx) {
    timer = Buddy::Timers.create!(
      user:         ctx.user,
      seconds:      payload[:seconds],
      label:        payload[:label],
      conversation: ctx.conversation,
    )
    { timer_id: timer.id, seconds: payload[:seconds].to_i, label: payload[:label].to_s }
  },
  receipt:     ->(result, ctx) {
    dur   = Buddy::Timers.humanize_seconds(result[:seconds])
    label = result[:label].to_s.strip
    "#{ctx.buddy_name} set a #{dur} timer#{" for #{label}" if label.present?} ⏲"
  },
)
