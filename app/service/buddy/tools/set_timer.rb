Buddy::Tools.register(
  name:        :set_timer,
  description: <<~TXT,
    Start a countdown timer that shows in your window and alarms when it's up.
    Use for "set a timer for 5 minutes", "10 minute timer for the pasta", "ping
    me in 90 seconds". Convert the duration to whole SECONDS. Give a short
    `label` when the person names what it's for ("pasta", "tea"); omit it
    otherwise. This is for short countdowns the person actively watches - for a
    nudge at a specific clock time, or a recurring one, use schedule_reminder.

    It's also how you WAIT. When they chain steps around a delay - "start the
    printer, wait a minute, then preheat it" - set the timer with
    `then_continue: true` and then call the later steps in the same reply. They
    won't fire now; they're held and run on their own the moment the timer's up.
    Call all of it in ONE reply, and never offer to do the last step later:
    that's the part they already asked for.
  TXT
  args:        {
    seconds:       { type: :integer, required: true,  description: "Countdown length in whole seconds" },
    label:         { type: :string,  required: false, description: "Short name for what the timer is for" },
    then_continue: {
      type:        :boolean,
      required:    false,
      description: "True only when this timer is a WAIT inside a sequence they asked for, and " \
                   "you are about to call the step that comes after it. Everything you call " \
                   "after this one is held back and runs when the timer's up. Leave it null " \
                   "for an ordinary countdown",
    },
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
    {
      timer_id: timer.id,
      seconds:  payload[:seconds].to_i,
      label:    payload[:label].to_s,
      waiting:  payload[Buddy::Tools::WAIT_ARG].present?,
    }
  },
  receipt:     ->(result, ctx) {
    dur   = Buddy::Timers.humanize_seconds(result[:seconds])
    label = result[:label].to_s.strip
    # A wait isn't a countdown they're watching, it's Buddy holding the rest of
    # the sequence, so the chip says that rather than announcing a timer.
    next "#{ctx.buddy_name} is waiting #{dur} before the next step ⏲" if result[:waiting]

    "#{ctx.buddy_name} set a #{dur} timer#{" for #{label}" if label.present?} ⏲"
  },
)
