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

    ROUND AND ROUND: `repeat: true` is for a rhythm rather than one countdown -
    "half an hour at a time", "30 on, 10 off until 6:30", "keep nudging me back
    to it". Add `break_minutes` when they named a break, and `until_time` when
    they named an hour to stop. When a block ends they get a button, the break
    starts counting on its own, and the NEXT block starts when they tap - never
    before. That is deliberate: a cycle that restarts on a schedule drifts away
    from the person inside two rounds. One call sets the whole thing up, so
    don't call this once per block, and don't promise a rhythm without
    `repeat`.

    Never offer to do the delayed part later; it's the part they already asked
    for, and the wait already holds it for you.
  TXT
  args:        {
    seconds:       { type: :integer, required: false, description: "Countdown length in whole seconds. Give this OR minutes, not both" },
    minutes:       { type: :integer, required: false, description: "Countdown length in whole minutes, when that's how they said it (\"30 minutes\"). Give this OR seconds, not both" },
    label:         { type: :string,  required: false, description: "Short name for what the timer is for" },
    repeat:        {
      type:        :boolean,
      required:    false,
      description: "True when they want to go round again and again rather than once - \"every 30 " \
                   "minutes\", \"another one after that\", a work/break rhythm. When it's up they " \
                   "get a button to start the next block, and nothing restarts until they tap it",
    },
    break_minutes: {
      type:        :integer,
      required:    false,
      description: "Minutes of BREAK between blocks, when they named one (\"30 on, 10 off\"). Needs " \
                   "repeat. The break starts counting the moment the block ends",
    },
    until_time:    {
      type:        :string,
      required:    false,
      description: "ISO8601 local time to stop offering another block (\"until 6:30\"). Needs repeat",
    },
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
  # Seconds OR minutes, and a length is the one thing this can't be called
  # without. Raising here drops the proposal, which is better than a one-second
  # countdown standing in for a thirty-minute one.
  confirm:     ->(payload, _ctx) {
    raise "a timer needs a length - give seconds or minutes" if Buddy::Tools::SetTimer.seconds(payload).zero?

    { summary: "Set a timer", resolved: {} }
  },
  label:       ->(payload, _ctx) { "Timer · #{Buddy::Timers.humanize_seconds(Buddy::Tools::SetTimer.seconds(payload))}" },
  execute:     ->(payload, ctx) {
    seconds = Buddy::Tools::SetTimer.seconds(payload)
    cycle   = ActiveModel::Type::Boolean.new.cast(payload[:repeat]).present?
    rest    = payload[:break_minutes].to_i * 60
    ends    = Buddy::Tools::SetTimer.until_at(payload, ctx)

    timer = (
      if cycle
        Buddy::TimerCycle.start!(
          user:          ctx.user,
          conversation:  ctx.conversation,
          seconds:       seconds,
          label:         payload[:label],
          break_seconds: rest.positive? ? rest : nil,
          until_at:      ends,
        )
      else
        Buddy::Timers.create!(
          user:         ctx.user,
          seconds:      seconds,
          label:        payload[:label],
          conversation: ctx.conversation,
        )
      end
    )

    {
      timer_id: timer.id,
      seconds:  seconds,
      label:    payload[:label].to_s,
      waiting:  payload[Buddy::Tools::WAIT_ARG].present?,
      cycle:    cycle,
      breaking: rest.positive? && cycle ? rest : nil,
      until_at: (ends&.strftime("%-l:%M %p")&.strip if cycle),
    }
  },
  receipt:     ->(result, ctx) {
    dur   = Buddy::Timers.humanize_seconds(result[:seconds])
    label = result[:label].to_s.strip
    # A wait isn't a countdown they're watching, it's Buddy holding the rest of
    # the sequence, so the chip says that rather than announcing a timer.
    next "#{ctx.buddy_name} is waiting #{dur} before the next step ⏲" if result[:waiting]

    if result[:cycle]
      on   = label.present? ? " on #{label}" : ""
      rest = (" then #{Buddy::Timers.humanize_seconds(result[:breaking])} off" if result[:breaking])
      till = (" until #{result[:until_at]}" if result[:until_at].present?)
      next "#{ctx.buddy_name} started #{dur}#{on}#{rest}#{till} ⏲"
    end

    "#{ctx.buddy_name} set a #{dur} timer#{" for #{label}" if label.present?} ⏲"
  },
)

module Buddy
  module Tools
    # Shared by three of the procs above, which each see only the raw payload.
    module SetTimer
      module_function

      # One length, whichever way they said it. Seconds wins if both arrive,
      # because it's the more specific of the two.
      def seconds(payload)
        return payload[:seconds].to_i if payload[:seconds].present?

        payload[:minutes].to_i * 60
      end

      # "until 6:30" as a real moment in their zone. Nil - rather than a
      # guessed hour - when it can't be read, so a cycle with an unparseable
      # end just runs until they stop tapping.
      def until_at(payload, ctx)
        raw = payload[:until_time].presence
        return nil if raw.nil?

        ctx.resolve_time(raw.to_s)
      rescue StandardError
        nil
      end
    end
  end
end
