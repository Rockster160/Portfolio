Buddy::Tools.register(
  name:        :set_rotation,
  description: <<~TXT,
    A loop around a job that isn't finished in one go, where each round ends by
    ASKING them. "Remind me to rotate the laundry every 75 minutes until it's
    done", "check the smoker every 45 minutes till it's ready", "nudge me back
    to the watering until I've done them all", "keep telling me to turn the
    ribs".

    A countdown shows on the hero the whole time. When it's up they get three
    buttons - go again, it's finished, or drop it - and NOTHING happens until
    they press one. Going again starts an identical countdown, so it circles for
    as long as the job takes.

    `again_label` is the button they'll press most, so word it as the thing they
    just did: "Rotated", "Turned", "Watered", "Checked". Leave it out and it
    says "Again", which is fine but says less.

    `done_item` + `done_list` are the follow-up the job leaves behind - what
    comes AFTER the rotating is over, not part of it. "Fold Laundry" onto their
    todo list when the laundry's finally done. Only set them when they named
    that follow-up; a loop with nothing to leave behind just ends.

    HOW TO TELL IT FROM `set_timer` with `repeat`. Both go round and both wait
    on a button, so read what the END OF A ROUND ASKS:

    - This one asks "is the JOB done yet?" - the loop exists because the job
      takes several passes and nobody knows how many. It ends when they say it's
      finished, and that answer can leave something behind.
    - `set_timer` + `repeat` is a WORK RHYTHM - "30 on, 10 off", blocks and
      breaks against the clock. It has breaks in it, it can end at an hour or on
      an event, and the button just starts the next block.

    If they named a break, or an hour to stop at, it's `set_timer`. If they're
    waiting on a THING to be done and each round is "did you go and do it", it's
    this one.

    Calling it again for something already going round RESTARTS that loop rather
    than starting a second one, and settles any question still on screen - which
    is how "I just rotated it" works said out loud instead of tapped. Use the
    same words for it they did the first time.

    For a nudge that's true whether or not they act on it, use
    schedule_reminder. For one countdown that just goes off, use set_timer.
  TXT
  args:        {
    label:       {
      type:        :string,
      required:    true,
      description: "What the loop is about, as they'd say it - \"Rotate the laundry\", \"Check the smoker\". " \
                   "Names the countdown and heads the question, and is what a later call matches on to restart it",
    },
    minutes:     { type: :integer, required: false, description: "How long between rounds, in whole minutes. Give this OR seconds, not both" },
    seconds:     { type: :integer, required: false, description: "How long between rounds, in whole seconds. Give this OR minutes, not both" },
    again_label: {
      type:        :string,
      required:    false,
      description: "The go-round-again button, worded as the thing they just did - \"Rotated\", " \
                   "\"Watered\", \"Turned\". Defaults to \"Again\"",
    },
    done_item:   {
      type:        :string,
      required:    false,
      description: "The follow-up to leave on a list once they say the job is finished (\"Fold Laundry\"). " \
                   "Only when they named one. Needs done_list",
    },
    done_list:   {
      type:        :string,
      required:    false,
      description: "Which list done_item goes on. Needs done_item",
    },
  },
  # Level 1 (auto), same as set_timer: a countdown they can swipe away, and the
  # loop asks before it does anything else.
  auto:        true,
  # Matches against whatever is going round at this moment, which is never the
  # same set twice — a saved copy would restart a loop they hadn't started yet.
  routinable:  false,
  confirm:     ->(payload, ctx) {
    label = payload[:label].to_s.strip
    raise "a rotation needs a name for what it's about" if label.blank?

    seconds = Buddy::Tools::SetRotation.seconds(payload)
    raise "a rotation needs a length - give minutes or seconds" if seconds.zero?

    item = payload[:done_item].to_s.strip
    list = payload[:done_list].to_s.strip
    raise "#{item.inspect} needs a list to go on" if item.present? && list.blank?

    {
      summary:  "Start a #{Buddy::Timers.humanize_seconds(seconds)} loop on #{label}",
      # A loop already going round for this thing is THE loop, whatever they
      # called it the second time — reusing its key is what makes a later call
      # restart it instead of running a second countdown alongside the first.
      resolved: { key: Buddy::Tools::SetRotation.key_for(ctx.user, label) },
    }
  },
  label:       ->(payload, _ctx) {
    "#{payload[:label]} · every #{Buddy::Timers.humanize_seconds(Buddy::Tools::SetRotation.seconds(payload))}"
  },
  execute:     ->(payload, ctx) {
    seconds = Buddy::Tools::SetRotation.seconds(payload)
    timer   = Buddy::RotationTimer.start!(
      user:         ctx.user,
      conversation: ctx.conversation,
      key:          payload[:key].presence || Buddy::Tools::SetRotation.key_for(ctx.user, payload[:label]),
      label:        payload[:label].to_s.strip,
      seconds:      seconds,
      again:        payload[:again_label].presence,
      follow_up:    { item: payload[:done_item].presence, list: payload[:done_list].presence },
      # Measured from the message that asked, same as set_timer — a slow turn
      # shouldn't quietly shave seconds off the interval they named.
      anchor:       :message,
    )
    raise "couldn't start that loop" if timer.nil?

    spec = Buddy::RotationTimer.spec_for(timer).to_h
    {
      timer_id: timer.id,
      seconds:  seconds,
      label:    payload[:label].to_s.strip,
      again:    spec["again"].to_s,
      item:     spec["item"].to_s,
      list:     spec["list"].to_s,
      round:    spec["round"].to_i,
    }
  },
  receipt:     ->(result, ctx) {
    dur   = Buddy::Timers.humanize_seconds(result[:seconds])
    label = result[:label].to_s.strip
    lands = (" · #{result[:item]} → #{result[:list]} when it's done" if result[:item].present?)
    # The receipt for a round that ISN'T the first one has to say so, or a
    # restart reads as a second loop starting beside the one already going.
    verb = result[:round].to_i > 1 ? "restarted" : "started"

    "#{ctx.buddy_name} #{verb} #{label} - asking every #{dur}#{lands} 🔁"
  },
)

module Buddy
  module Tools
    # Shared by the procs above, which each see only the raw payload.
    module SetRotation
      module_function

      # One length, whichever way they said it. Seconds wins if both arrive,
      # because it's the more specific of the two. Same rule as SetTimer.
      def seconds(payload)
        return payload[:seconds].to_i if payload[:seconds].present?

        payload[:minutes].to_i * 60
      end

      # The identity the loop keeps across rounds. A loop already going round
      # for this thing answers first — "start the laundry one again" has to
      # reach the laundry loop rather than open a second one beside it, and the
      # words won't be the same ones twice.
      def key_for(user, label)
        text = label.to_s.strip
        live = Buddy::Timers.live_for(user).find { |timer|
          spec = Buddy::RotationTimer.spec_for(timer)
          next false if spec.nil?

          name = spec["label"].to_s
          name.present? && (name.downcase.include?(text.downcase) || text.downcase.include?(name.downcase))
        }
        return Buddy::RotationTimer.spec_for(live)["key"].to_s if live

        text.parameterize.presence || "rotation"
      end
    end
  end
end
