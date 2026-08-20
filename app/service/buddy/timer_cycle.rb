module Buddy
  # Work / break cycles: "stay on the cupboards until 6:30, but give me ten
  # minutes off every half hour."
  #
  # A cycle is an ordinary Buddy timer carrying a `cycle` key in its metadata.
  # When it fires, instead of just announcing that time is up it posts a card
  # with ONE button, and the next block starts when that button is tapped.
  #
  # Nothing restarts on its own, and that is the whole design. `Timer#repeat`
  # exists and is driven by the CLIENT — it detects the fire and POSTs /start —
  # so a repeating timer keeps its own schedule whether or not the person came
  # back to it, and a cycle built on that drifts out of step with the human
  # inside two rounds. The tap is what keeps the two aligned: the next block
  # starts when they actually start.
  #
  # The break countdown is the one thing that DOES start by itself, at the
  # moment the button appears, because that's the half they want counted for
  # them. It's a plain timer with no cycle of its own, and tapping the button
  # early stops it — otherwise it fires in the middle of the next block and
  # announces a break that finished ten minutes ago.
  #
  # Prod: Eve asked for exactly this on 20 Aug (message 4135) and got one
  # 30-minute timer with an empty `then_continue` queue, plus a reply
  # describing a cycle that didn't exist.
  module TimerCycle
    module_function

    TOOL_NAME = "buddy_timer_cycle".freeze
    KEY       = "cycle".freeze
    RESUME    = "resume".freeze

    # A card nobody taps shouldn't be tappable next Tuesday. Long enough to
    # cover a break that ran over, short enough that yesterday's block can't be
    # restarted by a stray tap while scrolling.
    CARD_TTL = 6.hours

    # ---- reading one --------------------------------------------------------

    def cycle_for(timer)
      meta = timer&.metadata
      return nil unless meta.is_a?(Hash)

      cycle = meta[KEY]
      cycle.is_a?(Hash) ? cycle : nil
    end

    def cycle?(timer)
      cycle_for(timer).present?
    end

    # Past the end of what they asked for. Blank `until_at` means "keep going
    # until they stop tapping", which is a perfectly ordinary way to want this.
    def over?(cycle, now: Time.current)
      ends = cycle["until_at"].presence
      return false if ends.nil?

      Time.zone.parse(ends.to_s).then { |at| at.present? && now >= at }
    rescue StandardError
      false
    end

    # ---- starting one -------------------------------------------------------

    # The first block. Everything after it comes through `resume!`.
    def start!(user:, conversation:, seconds:, label: nil, break_seconds: nil, until_at: nil)
      Buddy::Timers.create!(
        user:         user,
        seconds:      seconds,
        label:        label,
        conversation: conversation,
        metadata:     {
          KEY => {
            "seconds"       => seconds.to_i,
            "break_seconds" => break_seconds.presence&.to_i,
            "until_at"      => until_at.presence&.then { |at| at.to_time.iso8601 },
            "label"         => label.to_s,
          }.compact,
        },
      )
    end

    # ---- the block ending ---------------------------------------------------

    # Called from Buddy::Timers.on_fired in place of the ordinary "time's up".
    def on_fired(timer, conversation)
      cycle = cycle_for(timer)
      return if cycle.nil?

      return finish!(timer, conversation, cycle) if over?(cycle)

      # Started BEFORE the card is posted, so the countdown they can see on the
      # hero is already running by the time they read the message telling them
      # to take it.
      rest = start_break(timer, conversation, cycle)
      offer!(timer, conversation, cycle, rest)
    end

    def start_break(timer, conversation, cycle)
      seconds = cycle["break_seconds"].to_i
      return nil unless seconds.positive?

      Buddy::Timers.create!(
        user:         timer.user,
        seconds:      seconds,
        label:        "Break",
        conversation: conversation,
      )
    rescue StandardError => e
      # A break that couldn't start is not a reason to withhold the button —
      # the block is over either way and they still need a way back in.
      Buddy::Errors.report(section: "timer_cycle.break", exception: e, user: timer.user)
      nil
    end

    def offer!(timer, conversation, cycle, rest)
      name    = conversation.buddy_name
      label   = cycle["label"].to_s.strip
      worked  = Buddy::Timers.humanize_seconds(cycle["seconds"])
      resting = (Buddy::Timers.humanize_seconds(cycle["break_seconds"]) if rest)

      message = Buddy::CompanionDelivery.deliver_plain(
        user:         timer.user,
        conversation: conversation,
        text:         fired_text(worked, label, resting),
        metadata:     { "kind" => "buddy", "source" => "timer_cycle", "timer_id" => timer.id },
        push_title:   label.present? ? "#{worked} on #{label}" : "#{worked} done",
      )

      attach_button!(timer.user, conversation, message, cycle, rest, worked)
    end

    def fired_text(worked, label, resting)
      done = label.present? ? "⏲ That's #{worked} on #{label}." : "⏲ That's #{worked}."
      return "#{done} Take #{resting} - I've started it. Tap below when you're ready for the next one." if resting

      "#{done} Tap below when you're ready for the next one."
    end

    # The card. `multi_select: false` and a single button, so it draws through
    # the ordinary action renderer with no client changes - one tap, and the
    # card settles into its decided state, which is also what stops a second
    # tap starting a second block.
    def attach_button!(user, conversation, message, cycle, rest, worked)
      button = { "id" => 1, "label" => "Start the next #{worked}", "value" => RESUME, "variant" => "primary" }

      action = ByteAction.create!(
        user:              user,
        byte_conversation: conversation,
        byte_message:      message,
        kind:              :custom,
        tool_name:         TOOL_NAME,
        multi_select:      false,
        buttons:           [button],
        tool_input:        { KEY => cycle, "break_timer_id" => rest&.id }.compact,
        expires_at:        CARD_TTL.from_now,
      )

      message.update!(metadata: message.metadata.to_h.merge(
        "tool_name"         => TOOL_NAME,
        "action_request_id" => action.request_id,
        "action_kind"       => "custom",
        "action_state"      => "pending",
        "multi_select"      => false,
        "buttons"           => [button],
      ))
      Buddy::Timers.broadcast_chip(user, message.reload)
      action
    end

    # Hand somebody the button without a block having just ended: picking a
    # rhythm back up after it was dropped, or starting one on their say-so
    # rather than off a countdown they're in the middle of. No break timer,
    # because nothing just finished — the wait is for them to be ready.
    def offer_start!(user:, conversation:, cycle:, text:, push_title: nil)
      message = Buddy::CompanionDelivery.deliver_plain(
        user:         user,
        conversation: conversation,
        text:         text,
        metadata:     { "kind" => "buddy", "source" => "timer_cycle" },
        push_title:   push_title || text.to_s.truncate(60),
      )

      attach_button!(user, conversation, message, cycle, nil, Buddy::Timers.humanize_seconds(cycle["seconds"]))
    end

    # ---- the tap ------------------------------------------------------------

    # Start the next block. Called from ByteController#respond_action once the
    # decision is recorded, so a second tap can't reach here - the action is no
    # longer pending and the request 409s before this runs.
    def resume!(action)
      input = action.tool_input.to_h
      cycle = input[KEY]
      return nil unless cycle.is_a?(Hash)

      conversation = action.byte_conversation
      user         = action.user

      # However much of the break is left is theirs to give up. Leaving it
      # running means it fires partway into the block they just started and
      # announces a break that's already over.
      stop_break(user, input["break_timer_id"])

      if over?(cycle)
        finish!(nil, conversation, cycle, user: user)
        return nil
      end

      timer = start!(
        user:          user,
        conversation:  conversation,
        seconds:       cycle["seconds"],
        label:         cycle["label"].presence,
        break_seconds: cycle["break_seconds"],
        until_at:      cycle["until_at"],
      )
      chip!(user, conversation, cycle, timer)
      timer
    rescue StandardError => e
      Buddy::Errors.report(section: "timer_cycle.resume", exception: e, user: action&.user)
      nil
    end

    def stop_break(user, timer_id)
      return if timer_id.blank?

      rest = user.timers.find_by(id: timer_id)
      Buddy::Timers.stop!(rest) if rest && rest.archived_at.nil?
    end

    def chip!(user, conversation, cycle, timer)
      label = cycle["label"].to_s.strip
      dur   = Buddy::Timers.humanize_seconds(cycle["seconds"])
      name  = conversation.buddy_name

      chip = conversation.byte_messages.create!(
        user:         user,
        direction:    :inbound,
        state:        :delivered,
        body:         "#{name} started the next #{dur}#{" on #{label}" if label.present?} ⏲",
        metadata:     {
          "kind"      => "buddy_activity",
          "tool_name" => "set_timer",
          "ok"        => true,
          "source"    => "timer_cycle",
          "timer_id"  => timer.id,
        },
        delivered_at: Time.current,
      )
      Buddy::Timers.broadcast_chip(user, chip)
      chip
    end

    # ---- the end of the day -------------------------------------------------

    # No button on this one. The hour they named has arrived, and offering
    # another block past it is the thing they set an end time to avoid.
    def finish!(timer, conversation, cycle, user: nil)
      label = cycle["label"].to_s.strip
      who   = user || timer&.user
      ends  = Time.zone.parse(cycle["until_at"].to_s)&.strftime("%-l:%M %p")&.strip

      Buddy::CompanionDelivery.deliver_plain(
        user:         who,
        conversation: conversation,
        text:         finished_text(label, ends),
        metadata:     { "kind" => "buddy", "source" => "timer_cycle", "timer_id" => timer&.id },
        push_title:   label.present? ? "#{label} - done for the day" : "That's the last block",
      )
    end

    def finished_text(label, ends)
      subject = label.present? ? " on #{label}" : ""
      return "⏲ That's #{ends} - you're done#{subject} for today. Nicely done 💛" if ends.present?

      "⏲ That's the last one#{subject}. Nicely done 💛"
    end
  end
end
