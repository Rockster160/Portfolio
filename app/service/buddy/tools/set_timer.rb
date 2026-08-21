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
    "half an hour at a time", "30 on, 10 off until 6:30", "check the printer
    every 30 minutes until the print finishes", "keep nudging me back to it".
    Add `break_minutes` when they named a break. When a block ends they get a
    button, the break starts counting on its own, and the NEXT block starts when
    they tap - never before. That is deliberate: a cycle that restarts on a
    schedule drifts away from the person inside two rounds. One call sets the
    whole thing up, so don't call this once per block, and don't promise a
    rhythm without `repeat`.

    **A REPEAT THEY HAVE TO ACT ON EACH TIME IS THIS TOOL, not
    `schedule_reminder`.** The test is whether each round asks them to DO
    something before the next one makes sense - go and look at the printer,
    get back to the cupboards, drink a glass of water. Then the next round
    starts when they've done it, which is what the button is for. A reminder
    fires on a clock whether or not they acted, which for that shape means
    fourteen nudges stacking up while they're away from it. Save
    `schedule_reminder` for a nudge that's true whether or not they're there.

    HOW IT ENDS, and it's one of three:
      - they stop tapping - the default, and fine
      - `until_time`, when they named an HOUR ("until 6:30")
      - `stop_when`, when they named a THING HAPPENING ("until the print
        finishes"). Same conditions `remind_when` takes. **Never turn one of
        those into a clock time** - it runs for fifteen minutes or fifteen
        years, whichever the thing takes.

    **The ending is never a reason not to start the rhythm.** If you can't work
    out how to wire the stop, `read_listener_guide` is one call away and will
    show you what the thing actually reports - and if it still won't go, set
    the repeat and say the stop isn't wired. Asked to "check my printer every
    30 minutes until the print finishes", a companion wrote the stop condition
    down as a feature request and set no timer at all, which leaves someone who
    asked for a rhythm with nothing running.

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
    stop_when:     {
      type:        :enum,
      required:    false,
      values:      Buddy::WatchCondition::TRIGGERS,
      description: "Stop the whole rhythm when this HAPPENS - \"until the print finishes\", \"until " \
                   "I get home\". Needs repeat. Not a time: it runs for fifteen minutes or fifteen " \
                   "years, whichever the thing takes",
    },
    stop_target:   { type: :string, required: false, description: "Place / chore / event / calendar name the stop condition is about. With stop_when." },
    stop_listener: { type: :string, required: false, description: "Jil listener string, for stop_when=custom. Read read_listener_guide first." },
    stop_phrase:   { type: :string, required: false, description: "Plain-language meaning of the stop listener. Required for stop_when=custom." },
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

    # The condition that ends it, resolved before anything is built but never
    # allowed to take the timer down with it — the countdown they asked for is
    # good whether or not its ending could be wired.
    stop, stop_error = Buddy::Tools::SetTimer.stop_condition(payload, ctx) if cycle

    unless cycle
      plain = Buddy::Timers.create!(
        user:         ctx.user,
        seconds:      seconds,
        label:        payload[:label],
        conversation: ctx.conversation,
      )
      next { timer_id: plain.id, seconds: seconds, label: payload[:label].to_s, waiting: payload[Buddy::Tools::WAIT_ARG].present? }
    end

    timer = Buddy::TimerCycle.start!(
      user:          ctx.user,
      conversation:  ctx.conversation,
      seconds:       seconds,
      label:         payload[:label],
      break_seconds: rest.positive? ? rest : nil,
      # An EVENT ending is not a clock ending, and the two must never be mixed:
      # a cycle that stops when the print finishes has no hour attached to it
      # at all, or the hour arrives first and stops it early.
      until_at:      (ends unless stop),
    )
    watch = (Buddy::TimerCycle.stop_on!(timer, ctx.conversation, stop) if stop)

    {
      timer_id:   timer.id,
      seconds:    seconds,
      label:      payload[:label].to_s,
      waiting:    payload[Buddy::Tools::WAIT_ARG].present?,
      cycle:      true,
      breaking:   rest.positive? ? rest : nil,
      until_at:   (ends&.strftime("%-l:%M %p")&.strip unless stop),
      stop_human: (stop&.human if watch),
      stop_failed: (
        if stop_error.present?
          "THE TIMER IS RUNNING. The stopping rule is NOT: #{stop_error}. Say both - what you " \
            "started, and that it won't stop on its own yet - and offer `request_feature` for the " \
            "ending. Never describe a stopping rule you haven't set."
        end
      ),
    }.compact
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
      # The ending, in whichever of the three shapes it has. An event ending is
      # said as the event — turning it into a clock time is the thing this is
      # here to stop.
      till = (
        if result[:stop_human].present? then ", #{Buddy::WatchCondition.until_phrase(result[:stop_human])}"
        elsif result[:until_at].present? then " until #{result[:until_at]}"
        elsif result[:stop_failed].present? then " (won't stop on its own)"
        end
      )
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

      # [condition, error]. Degrades rather than raising, for the same reason
      # the reminder's does: an ending that can't be wired is a reason to run
      # the rhythm without one and say so, not a reason to abandon the rhythm.
      def stop_condition(payload, ctx)
        return [nil, nil] if payload[:stop_when].to_s.strip.blank?

        gate = { gated_values: { stop_when: Buddy::WatchCondition::GATED } }
        arg, feature = Buddy::Features.gated_arg(ctx.user, gate, payload)
        raise "watching for that needs #{Buddy::Features.label_for(feature)}" if arg

        [
          Buddy::WatchCondition.resolve(
            {
              trigger:     payload[:stop_when],
              target:      payload[:stop_target],
              listener:    payload[:stop_listener],
              when_phrase: payload[:stop_phrase],
            },
            ctx,
          ),
          nil,
        ]
      rescue StandardError => e
        [nil, e.message]
      end
    end
  end
end
