Buddy::Tools.register(
  name:        :set_timer,
  description: <<~TXT,
    Start a countdown timer that shows in your window and alarms when it's up.
    Use for "set a timer for 5 minutes", "10 minute timer for the pasta", "ping
    me in 90 seconds". Convert the duration to whole SECONDS. Give a short
    `label` when the person names what it's for ("pasta", "tea"); omit it
    otherwise. This is for short countdowns the person actively watches - for a
    recurring nudge, use schedule_reminder.

    When they say ALARM, use `alarm`. It reaches a clock time as well as a
    duration, and what goes off says what it was set for rather than that a
    timer is up - "Wake up" instead of "your Wake up timer's done". Follow the
    word they used; "timer" is this one.

    It's also how you WAIT, and it is the ONLY way to make something happen
    later than right now without pinning it to a clock time. Set the timer with
    `then_continue: true` and call the delayed steps after it in the SAME reply.
    They don't fire now; they're held and run on their own the moment the timer
    is up.

    Two shapes need it, not one:

    - A chain - "start the printer, wait a minute, then preheat it". The first
      step, then the timer, then the rest.
    - A single thing put off - **"add the milk to my list in 2 minutes", "take
      that off the board in a bit"**. There's no step before the wait, and that
      does NOT make it an ordinary countdown: the timer comes first, then the
      one action. Calling the action on its own does it immediately, which is
      the opposite of what they asked for.

    A wait holds a step that hasn't happened yet. Some tools say in their own
    description that a wait CANNOT hold them - they act the instant they are
    called, before the wait is even set - and a delay on one of those goes on a
    real schedule instead: schedule_function, schedule_trigger,
    schedule_reminder or alarm. Sounds, devices and Jil functions are the ones
    to look twice at.

    The test is whether they named something to happen AFTER a delay. If they
    did, the timer carries `then_continue: true`. A bare "set a timer for 10" -
    nothing named to follow it - is the ordinary countdown, and that one leaves
    the flag off.

    Never offer to do the delayed part later; it's the part they already asked
    for, and the wait already holds it for you.
  TXT
  args:        {
    seconds:       { type: :integer, required: true,  description: "Countdown length in whole seconds" },
    label:         { type: :string,  required: false, description: "Short name for what the timer is for" },
    then_continue: {
      type:        :boolean,
      required:    false,
      description: "True whenever they named something to happen AFTER this delay, whether " \
                   "or not a step came before it - a chain, or a single action put off " \
                   "(\"play the nap sound in 2 minutes\"). Everything you call after this one " \
                   "is held back and runs when the timer's up. Leave it null only for a bare " \
                   "countdown with nothing named to follow",
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
